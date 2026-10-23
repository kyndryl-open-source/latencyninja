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

# Backup and Logging
declare -g backup_dir="" log_file=""

# Snapshots and Persistence
declare -g state_root="/run/latencyninja" state_dir="/run/latencyninja" persist_dir="/etc/latencyninja/persist" unit_file="/etc/systemd/system/latencyninja@.service" udev_rule_file="/etc/udev/rules.d/99-latencyninja.rules" watcher_unit_file="/etc/systemd/system/latencyninja-namespaces.service"
declare -g save_file="" restore_file="" apply_persisted="" persist=0 keep_persist=0

# Inside a target namespace (--netns/--pid/--container), keep state separate from the host's
[ -n "$LATENCYNINJA_NETNS_KEY" ] && state_dir="$state_dir/ns/$LATENCYNINJA_NETNS_KEY"

# Profiles (built-in profiles ship with Latency Ninja; files in the user directory take precedence)
declare -g profile="" profiles_dir="$script_dir/profiles" user_profiles_dir="/etc/latencyninja/profiles"

# Timed rollback
declare -g duration="" duration_seconds="" timed_rollback_file=""

# Function to check full paths of commands
find_command_paths() {
    local required_commands=("tc" "ping" "ip" "modprobe" "curl" "jq")

    # git is only required for --update
    if [[ "$update_requested" -eq 1 ]]; then
        required_commands+=("git")
    fi

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