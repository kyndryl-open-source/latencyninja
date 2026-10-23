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

# Function to capture a restorable snapshot of all Latency Ninja rules before changes
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

    write_snapshot "$backup_file" || die "Failed to write backup file: $backup_file"
}

# Function to append applied tc values to the backup file (as comments, for reference)
append_applied_values() {
    local backup_file="$1"

    {
        echo "### Applied TC Values ###"
        echo ""
        in_namespace && echo "Namespace: $LATENCYNINJA_NETNS_DESC"
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
        [ -n "$rate" ] && echo "Rate: ${rate}"
        [ -n "$profile" ] && echo "Profile: ${profile}"
        [ -n "$duration" ] && echo "Duration: ${duration}"
    } | sed 's/^/# /' >> "$backup_file"
}
