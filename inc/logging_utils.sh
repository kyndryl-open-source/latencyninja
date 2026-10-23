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

# Function to log execution details to the log file
log_execution() {
    local log_file="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local log_dir
    log_dir=$(dirname "$log_file")

    if [ ! -d "$log_dir" ]; then
        die "Log directory does not exist: $log_dir"
    fi

    if [ -f "$log_file" ] && [ ! -w "$log_file" ]; then
        die "Log file is not writable: $log_file"
    elif [ ! -f "$log_file" ] && [ ! -w "$log_dir" ]; then
        die "Log directory is not writable: $log_dir"
    fi

    {
        echo "[$timestamp] Execution Start"
        echo "  Command: $0 $*"
        [ -n "$eth_interface" ] && echo "  Interface: $eth_interface"
        for sip in "${src_ip[@]}"; do
            [ -n "$sip" ] && echo "  Source IP: $sip"
        done
        for dip in "${dst_ip[@]}"; do
            [ -n "$dip" ] && echo "  Destination IP: $dip"
        done
        [ -n "$direction" ] && echo "  Direction: $direction"

        local params=""
        [ -n "$latency" ] && params="${params}Latency: ${latency}ms, "
        [ -n "$jitter" ] && params="${params}Jitter: ${jitter}ms, "
        [ -n "$packet_loss" ] && params="${params}Packet Loss: ${packet_loss}%, "
        [ -n "$duplicate" ] && params="${params}Duplicate: ${duplicate}%, "
        [ -n "$corrupt" ] && params="${params}Corrupt: ${corrupt}%, "
        [ -n "$reorder" ] && params="${params}Reorder: ${reorder}%, "
        [ -n "$rate" ] && params="${params}Rate: ${rate}, "
        # Remove trailing comma and space
        params="${params%, }"
        [ -n "$params" ] && echo "  Parameters: $params"
        [ -n "$profile" ] && echo "  Profile: $profile"
        [ -n "$duration" ] && echo "  Duration: $duration (rollback at $(date -d "+${duration_seconds} seconds" '+%Y-%m-%d %H:%M:%S'))"

        echo "  Affected Rules:"
        if [ "$direction" == "ingress" ] || [ "$direction" == "both" ]; then
            local ingress_netem
            ingress_netem=$($tc_path -s qdisc show dev "$ifb0_interface" 2>/dev/null | grep -E "delay|loss|duplicate|reorder|corrupt|rate")
            [ -n "$ingress_netem" ] && echo "    - Ingress ($ifb0_interface): $ingress_netem"
        fi
        if [ "$direction" == "egress" ] || [ "$direction" == "both" ]; then
            local egress_netem
            egress_netem=$($tc_path -s qdisc show dev "$ifb1_interface" 2>/dev/null | grep -E "delay|loss|duplicate|reorder|corrupt|rate")
            [ -n "$egress_netem" ] && echo "    - Egress ($ifb1_interface): $egress_netem"
        fi

        echo "[$timestamp] Execution Complete"
        echo ""
    } >> "$log_file"
}
