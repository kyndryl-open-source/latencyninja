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

# Function to determine if a destination is a single host IP or a network
is_single_host() {
    local host="$1" ip_part="${host%%/*}" subnet_mask="${host#*/}"
    [[ "$host" == *"/"* ]] && { IFS='.' read -ra ip_octets <<< "$ip_part"; [[ "$subnet_mask" =~ ^[0-9]+$ ]] && ((subnet_mask >= 0 && subnet_mask <= 32)) && { [[ ${#ip_octets[@]} -gt 1 || "$subnet_mask" != "32" ]] && return 1; }; }
    return 0
}

# Function to list network devices. Uses ip rather than /sys/class/net, which keeps showing the
# host's devices inside a namespace entered with nsenter --net.
list_network_devices() {
    $ip_path -o link show | awk -F': ' '{print $2}' | sed 's/@.*//'
}

# Function to derive the ifb names for an interface so several interfaces can be shaped at once
set_ifb_interfaces() {
    local interface="$1"
    ifb0_interface=$(ifb_name_for "lni-" "$interface")
    ifb1_interface=$(ifb_name_for "lne-" "$interface")
}

# Function to build an ifb name; names are limited to 15 characters so long ones use a checksum
ifb_name_for() {
    local prefix="$1" interface="$2"
    local name="${prefix}${interface}"
    if [ "${#name}" -gt 15 ]; then
        name="${prefix}$(printf '%s' "$interface" | cksum | awk '{print substr($1, 1, 11)}')"
    fi
    echo "$name"
}

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
    local silent="$1"
    
    if [ "$rollback_required" -eq 1 ] && [ "$rollback_done" -eq 0 ]; then
        [[ "$silent" != "silent" ]] && echo -n "Rolling back network perturbations changes. "
        
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

# Function to describe the Latency Ninja state of an interface (rules, persistence, timed rollback)
interface_ninja_status() {
    local interface="$1" ip_cmd="$2"
    local status="" directions="" expires left

    $ip_cmd link show "$(ifb_name_for "lni-" "$interface")" &>/dev/null && directions="ingress"
    if $ip_cmd link show "$(ifb_name_for "lne-" "$interface")" &>/dev/null; then
        [ -n "$directions" ] && directions="both" || directions="egress"
    fi
    [ -n "$directions" ] && status="rules ($directions)"
    is_persisted "$interface" && status="${status:+$status, }persisted"
    expires="$state_dir/$interface.expires"
    if [ -r "$expires" ]; then
        left=$(( $(cat "$expires") - $(date +%s) ))
        [ "$left" -gt 0 ] && status="${status:+$status, }rollback in $((left / 60))m $((left % 60))s"
    fi
    echo "${status:--}"
}

# Function to display the network interfaces that rules can be applied to.
# Works without root; persistence and timed rollbacks are only visible to root.
# Based on a contribution by Stan Cope (@scopey).
show_available_interfaces() {
    local ip_cmd="${ip_path:-$(command -v ip)}"
    local jq_cmd="${jq_path:-$(command -v jq)}"
    local name state kind slave master link_type address type

    [ -n "$ip_cmd" ] || die "The 'ip' command is required but it's not installed."
    [ -n "$jq_cmd" ] || die "The 'jq' command is required but it's not installed."

    echo
    in_namespace && echo -e "Namespace: $LATENCYNINJA_NETNS_DESC\n"
    printf "%-16s %-8s %-30s %-20s %s\n" "INTERFACE" "STATE" "TYPE" "IPV4" "LATENCY NINJA"
    # ifb devices are used internally by Latency Ninja (lni-*/lne-*) and the ifb module, so they're hidden
    # "|" rather than tabs: read collapses consecutive whitespace delimiters, which would shift empty fields
    while IFS='|' read -r name state kind slave master link_type; do
        [ "$link_type" = "loopback" ] || [ "$kind" = "ifb" ] && continue
        case "$kind" in
            "") [ "$link_type" = "ether" ] && type="ethernet" || type="$link_type" ;;
            *) type="$kind" ;;
        esac
        [ -n "$master" ] && type="$type ($slave member of $master)"
        address=$($ip_cmd -j -4 address show dev "$name" 2>/dev/null | $jq_cmd -r '[.[].addr_info[] | "\(.local)/\(.prefixlen)"] | first // "-"')
        printf "%-16s %-8s %-30s %-20s %s\n" "$name" "$state" "$type" "${address:--}" "$(interface_ninja_status "$name" "$ip_cmd")"
    done < <($ip_cmd -j -d link show | $jq_cmd -r '.[] | [.ifname, .operstate, (.linkinfo.info_kind // ""), (.linkinfo.info_slave_kind // ""), (.master // ""), .link_type] | join("|")')

    if [ "$(id -u)" -ne 0 ]; then
        echo
        echo "Run as root to also see persisted rules and timed rollbacks."
    fi
    echo
}
