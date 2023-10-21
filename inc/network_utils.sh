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

# Function to create virtual interfaces
create_virtual_interface() {
    local interface="$1"

    # Ensure interface parameter is provided
    if [[ -z $interface ]]; then
        die "No interface name provided to create_virtual_interface function."
    fi

    # Check if the interface already exists
    if $ip_path link show "$interface" &>/dev/null; then
        $ip_path link set "$interface" down
        $ip_path link set "$interface" up
    else
        $ip_path link add "$interface" type ifb || die "Failed to create $interface."
    fi
}

# Function to bring up the interfaces
bring_up_interface() {
    local interface="$1"

    # Ensure interface parameter is provided
    if [[ -z $interface ]]; then
        die "No interface name provided to bring_up_interface function."
    fi

    $ip_path link set dev "$interface" up || die "Failed to bring up $interface."
}
# Function to delete existing qdisc if it exists
delete_qdisc_if_exists() {
    local interface="$1"
    local qdisc_type="$2"
    local handle="$3"

    # Ensure interface parameter is provided
    if [[ -z $interface ]] || [[ -z $qdisc_type ]] || [[ -z $handle ]]; then
        die "Missing parameters in delete_qdisc_if_exists function."
    fi

    if $tc_path qdisc show dev "$interface" | grep -qw "$handle"; then
        $tc_path qdisc del dev "$interface" "$qdisc_type" 2>/dev/null || {
            echo -e "Failed to remove existing qdisc on $interface." >&2
            rollback_everything
            exit 1
        }
    fi
}

# Function to rollback network perturbations changes
rollback_everything() {
    if [ "$rollback_required" -eq 1 ] && [ "$rollback_done" -eq 0 ]; then
        echo -n "Rolling back network perturbations changes. "
        # Ensure global variables are not empty
        if [[ -z $tc_path ]] || [[ -z $ip_path ]] || [[ -z $eth_interface ]] || \
           [[ -z $ifb0_interface ]] || [[ -z $ifb1_interface ]]; then
            die "Missing required global variables in rollback_everything function."
        fi
        # Remove tc Filters
        $tc_path filter del dev "$eth_interface" parent 1: 2>/dev/null
        $tc_path filter del dev "$eth_interface" parent ffff: 2>/dev/null
        # Flush tc qdiscs
        $tc_path qdisc del dev "$ifb0_interface" root 2>/dev/null
        $tc_path qdisc del dev "$ifb1_interface" root 2>/dev/null
        $tc_path qdisc del dev "$eth_interface" ingress 2>/dev/null
        $tc_path qdisc del dev "$eth_interface" root 2>/dev/null
        # Remove ifb virtual interfaces
        $ip_path link delete dev "$ifb0_interface" 2>/dev/null
        $ip_path link delete dev "$ifb1_interface" 2>/dev/null
        rollback_done=1
    fi
}