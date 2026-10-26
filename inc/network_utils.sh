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
        
        # The qdiscs of the interface are only removed when they are ours (the root prio 1: and the ingress qdisc
        # redirecting to an ifb device), unless the rules are about to be replaced
        if [ "$replace_foreign_qdiscs" -eq 1 ] || $tc_path qdisc show dev "$eth_interface" 2>/dev/null | grep -q '^qdisc prio 1: root'; then
            $tc_path filter del dev "$eth_interface" parent 1: 2>/dev/null
            $tc_path qdisc del dev "$eth_interface" root 2>/dev/null
        fi
        if [ "$replace_foreign_qdiscs" -eq 1 ] || $tc_path filter show dev "$eth_interface" ingress 2>/dev/null | grep -q 'Redirect to device'; then
            $tc_path filter del dev "$eth_interface" parent ffff: 2>/dev/null
            $tc_path qdisc del dev "$eth_interface" ingress 2>/dev/null
        fi

        # Flush the qdiscs of the ifb devices
        $tc_path qdisc del dev "$ifb0_interface" root 2>/dev/null
        $tc_path qdisc del dev "$ifb1_interface" root 2>/dev/null
        
        # Remove ifb virtual interfaces
        $ip_path link delete dev "$ifb0_interface" 2>/dev/null
        $ip_path link delete dev "$ifb1_interface" 2>/dev/null
        
        rollback_done=1
    fi
}

# Function to warn when applying rules replaces qdiscs that Latency Ninja didn't set up. They are removed (a root
# qdisc and an ingress or clsact qdisc are needed for the rules) and --rollback doesn't bring them back.
warn_foreign_qdiscs() {
    local interface="$1" root type
    root=$($tc_path qdisc show dev "$interface" 2>/dev/null | awk '$1 == "qdisc" && $4 == "root" {print $2, $3; exit}')
    case "$root" in
        ""|"prio 1:"|noqueue*|mq*|pfifo_fast*|fq_codel*|"fq "*|pfifo*|bfifo*) ;;
        *) echo "Warning: $interface has a ${root% *} root qdisc, which is replaced by the rules and not restored by --rollback (the previous qdiscs are recorded in the backup file)." >&2 ;;
    esac
    type=$($tc_path qdisc show dev "$interface" 2>/dev/null | awk '$1 == "qdisc" && ($2 == "clsact" || $2 == "ingress") {print $2; exit}')
    if [ "$type" = "clsact" ] || { [ "$type" = "ingress" ] && ! $tc_path filter show dev "$interface" ingress 2>/dev/null | grep -q 'Redirect to device'; }; then
        echo "Warning: $interface has an $type qdisc (e.g. for eBPF programs or ingress filters), which is replaced by the rules and not restored by --rollback." >&2
    fi
}

# Function to undo a failed apply (including Ctrl-C): remove what was set up and bring back the rules from before
undo_failed_apply() {
    local code=$?
    [ "$apply_in_progress" -eq 1 ] || return 0
    apply_in_progress=0
    trap - EXIT
    echo >&2
    echo "Applying the rules failed, restoring the previous rules of $eth_interface." >&2
    # Restoring re-applies the previous rules, which cancels their pending timed rollback: keep it
    local left=0 pending_backup=""
    if [ -f "$state_dir/$eth_interface.expires" ] && [ -f "$state_dir/$eth_interface.backup" ]; then
        left=$(( $(cat "$state_dir/$eth_interface.expires") - $(date +%s) ))
        pending_backup=$(cat "$state_dir/$eth_interface.backup")
    fi
    rollback_done=0
    replace_foreign_qdiscs=1
    rollback_everything silent
    if [ -f "$backup_file" ] && ( restore_snapshot "$backup_file" "$eth_interface" ) &>/dev/null; then
        echo "Previous rules restored." >&2
        [ "$left" -gt 0 ] && [ -f "$pending_backup" ] && schedule_rollback "$eth_interface" "$left" "$pending_backup" >/dev/null
    else
        echo "The previous rules could not be restored, see: sudo $0 --restore $backup_file$(namespace_hint)" >&2
    fi
    exit "$code"
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
    echo
}
