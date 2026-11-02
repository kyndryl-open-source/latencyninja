#!/bin/bash
# This file is part of Latency Ninja.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License v2.0 as published by
# the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Latency Ninja.  If not, see <https://www.gnu.org/licenses/>.

# Application Information
declare -g app_name="Latency Ninja" current_version="$(cat "$script_dir/version.txt" 2>/dev/null)"

# Updater Information
declare -g repo_url="https://github.com/kyndryl-open-source/latencyninja.git" version_url="https://raw.githubusercontent.com/kyndryl-open-source/latencyninja/main/version.txt" version_file="$script_dir/version.txt" 

# Network Interfaces (ifb names are derived per interface by set_ifb_interfaces: lni-<iface> ingress, lne-<iface> egress)
declare -g ifb0_interface="" ifb1_interface="" eth_interface=""

# Local IP address, source and destination IPs. The *_arg variables keep the raw values given by the user.
declare -g local_ip="" src_ip=() dst_ip=() src_ip_arg="" dst_ip_arg=""

# JSON File
declare -g json_file=""

# Network perturbation earameters
declare -g latency="" jitter="" packet_loss="" duplicate="" corrupt="" reorder="" rate=""

# Options and Flags
declare -g direction="both"  # Traffic direction for shaping (options: both, inbound, outbound).
declare -g interface_provided=0 jitter_provided=0 latency_provided=0  # Flags for user-provided options.
declare -g rollback_required=0 rollback_done=0 ips_swapped=0  # Flags for script behavior and state.
declare -g replace_foreign_qdiscs=0 apply_in_progress=0 backup_file=""  # Replacing qdiscs we didn't set up, undoing a failed apply.

# Backup and Logging (the execution log and the audit log live in /var/log/latencyninja unless a path is given)
declare -g backup_dir="" log_file="" audit_log="" audit_actor="" audit_command="" audit_details=()
declare -g default_log_dir="/var/log/latencyninja"
declare -g default_log_file="$default_log_dir/latencyninja.log" default_audit_log="$default_log_dir/audit.log"

# Snapshots and Persistence
declare -g state_root="/run/latencyninja" state_dir="/run/latencyninja" persist_dir="${LATENCYNINJA_PERSIST_DIR:-/etc/latencyninja/persist}" unit_file="/etc/systemd/system/latencyninja@.service" udev_rule_file="/etc/udev/rules.d/99-latencyninja.rules" watcher_unit_file="/etc/systemd/system/latencyninja-namespaces.service"
declare -g save_file="" restore_file="" apply_persisted="" persist=0 keep_persist=0

# Inside a target namespace (--netns/--pid/--container), keep state separate from the host's
[ -n "$LATENCYNINJA_NETNS_KEY" ] && state_dir="$state_dir/ns/$LATENCYNINJA_NETNS_KEY"

# Profiles (built-in profiles ship with Latency Ninja; files in the user directory take precedence)
declare -g profile="" profiles_dir="$script_dir/profiles" user_profiles_dir="/etc/latencyninja/profiles"

# Timed rollback, and the dead-man switch (--confirm-within: a timed rollback that --confirm cancels)
declare -g duration="" duration_seconds="" timed_rollback_file=""
declare -g confirm_within="" confirm_pending=0 confirm_mode=0

# Output format of --query, --show-interfaces, --stats and --status (text or json), and the --stats mode
declare -g output_format="text" query_mode=0 interfaces_mode=0 stats_mode=0

# Probing the effect of the rules (--probe), measured before and after they are applied
declare -g probe="" probe_count=5 probe_kind=""

# Detached runs (--run-in background|screen|tmux, --status, --wait). run_id is set in the detached process itself.
declare -g run_in="" run_id="" status_mode=0 status_id="" wait_id=""
declare -g runs_dir="$state_root/runs"

# SSH lockout guard bypass, the --check/--clean modes and --dry-run
declare -g allow_ssh=0 check_mode=0 clean_mode=0 assume_yes=0 dry_run=0

# Function to note the optional features asked for on the command line, so only the commands they need are
# required: git for --update, curl for --update and --probe, screen or tmux for --run-in
scan_requested_features() {
    update_requested=0 probe_requested=0 run_in_requested=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --update) update_requested=1 ;;
            --probe) probe_requested=1 ;;
            --background) run_in_requested="background" ;;
            --run-in) run_in_requested="$2" ;;
        esac
        shift
    done
}

# Function to check full paths of commands
find_command_paths() {
    local required_commands=("tc" "ip" "modprobe" "jq")

    # git is only required for --update, curl for --update and --probe
    [[ "$update_requested" -eq 1 ]] && required_commands+=("git")
    [[ "$update_requested" -eq 1 || "$probe_requested" -eq 1 ]] && required_commands+=("curl")
    # screen or tmux are only required when --run-in selects them
    [[ "$run_in_requested" == "screen" || "$run_in_requested" == "tmux" ]] && required_commands+=("$run_in_requested")

    local cmd
    local cmd_path
    local var_name

    for cmd in "${required_commands[@]}"; do
        cmd_path=$(command -v "$cmd" 2>/dev/null)
        if [[ -z $cmd_path ]]; then
            die "The '$cmd' command is required but it's not installed. Please install it and retry."
        else
            var_name="${cmd}_path"
            declare -g "$var_name=$cmd_path"
        fi
    done
}

# Debugging
declare -g debug=false