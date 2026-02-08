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

# Function to capture a snapshot of all tc rules before changes
backup_tc_snapshot() {
    local backup_file="$1"
    local target_dir

    target_dir=$(dirname "$backup_file")

    if [ ! -d "$target_dir" ]; then
        die "Backup directory does not exist: $target_dir"
    fi

    if [ ! -w "$target_dir" ]; then
        die "Backup directory is not writable: $target_dir"
    fi

    local devices
    devices=$(ls /sys/class/net/)

    {
        echo "# Latency Ninja TC Backup"
        echo "# Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "### Previous TC Rules ###"
        echo ""

        for dev in $devices; do
            local qdisc_output filter_output class_output
            qdisc_output=$($tc_path qdisc show dev "$dev" 2>/dev/null)
            filter_output=$($tc_path filter show dev "$dev" 2>/dev/null)
            class_output=$($tc_path class show dev "$dev" 2>/dev/null)

            # Skip devices with no tc configuration
            [ -z "$qdisc_output" ] && [ -z "$filter_output" ] && [ -z "$class_output" ] && continue

            echo "# Device: $dev"

            if [ -n "$qdisc_output" ]; then
                echo "# Qdiscs:"
                echo "$qdisc_output"
            fi

            if [ -n "$filter_output" ]; then
                echo "# Filters:"
                echo "$filter_output"
            fi

            if [ -n "$class_output" ]; then
                echo "# Classes:"
                echo "$class_output"
            fi

            echo ""
        done
    } > "$backup_file"

    if [ $? -ne 0 ]; then
        die "Failed to write backup file: $backup_file"
    fi
}

# Function to append applied tc values to the backup file
append_applied_values() {
    local backup_file="$1"

    {
        echo "### Applied TC Values ###"
        echo ""
        [ -n "$eth_interface" ] && echo "Interface: $eth_interface"
        [ -n "$direction" ] && echo "Direction: $direction"
        for sip in "${src_ip[@]}"; do
            [ -n "$sip" ] && echo "Source IP: $sip"
        done
        for dip in "${dst_ip[@]}"; do
            [ -n "$dip" ] && echo "Destination IP: $dip"
        done
        [ -n "$latency" ] && echo "Latency: ${latency}ms"
        [ -n "$jitter" ] && echo "Jitter: ${jitter}ms"
        [ -n "$packet_loss" ] && echo "Packet Loss: ${packet_loss}%"
        [ -n "$duplicate" ] && echo "Duplicate: ${duplicate}%"
        [ -n "$corrupt" ] && echo "Corrupt: ${corrupt}%"
        [ -n "$reorder" ] && echo "Reorder: ${reorder}%"
        echo ""
    } >> "$backup_file"
}
