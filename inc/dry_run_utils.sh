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

# --dry-run runs the real code path with tc, ip and modprobe replaced by the functions below, so the commands
# shown are the ones that would be run. They print the command instead of running it. Queries (show) print
# nothing and fail, which is what the real run sees after it has removed the existing rules.
dry_run_command() {
    local tool="$1"
    shift
    [ "$2" = "show" ] || [ "$1" = "show" ] && return 1
    printf '  %s' "$tool"
    printf ' %s' "$@"
    echo
}

dry_run_tc() { dry_run_command tc "$@"; }
dry_run_ip() { dry_run_command ip "$@"; }
dry_run_modprobe() { dry_run_command modprobe "$@"; }

# Function to show what would be done for the given arguments, without changing anything
dry_run_plan() {
    local arg apply_args=()
    for arg in "$@"; do
        [ "$arg" = "--dry-run" ] || apply_args+=("$arg")
    done

    display_params "Would apply"

    echo "Commands that would be run:"
    tc_path=dry_run_tc ip_path=dry_run_ip modprobe_path=dry_run_modprobe
    rollback_required=1 rollback_done=0 replace_foreign_qdiscs=1
    load_ifb_module
    rollback_everything silent
    if [ "$direction" == "ingress" ] || [ "$direction" == "both" ]; then
        create_virtual_interface "$ifb0_interface"
        bring_up_interface "$ifb0_interface"
        configure_ingress_traffic_controls "$eth_interface" "$ifb0_interface" src_ip[@] dst_ip[@] "$latency" "$jitter" "$packet_loss" "$duplicate" "$corrupt" "$reorder" "$rate"
    fi
    if [ "$direction" == "egress" ] || [ "$direction" == "both" ]; then
        create_virtual_interface "$ifb1_interface"
        bring_up_interface "$ifb1_interface"
        configure_egress_traffic_controls "$eth_interface" "$ifb1_interface" src_ip[@] dst_ip[@] "$latency" "$jitter" "$packet_loss" "$duplicate" "$corrupt" "$reorder" "$rate"
    fi

    echo
    [ -n "$duration" ] && echo "The rules would be rolled back automatically after $duration."
    [ "$persist" -eq 1 ] && echo "The rules would be persisted and re-applied at boot."
    echo "Dry run: nothing was changed, no backup was taken and no log entry was written."
    echo "To apply, run: sudo $0 ${apply_args[*]}"
    echo
}
