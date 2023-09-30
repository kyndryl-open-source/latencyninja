#!/bin/bash

# Latency Ninja - v0.1alpha
#
# Latency Ninja is a wrapper tool for tc/netem to simulate network perturbations by applying latency,
# jitter, packet loss, and more to a single destination IP address.
# 
# Features:
# - Apply network perturbations to an interface and destination IP address.
# - Simulate latency, kitter, packet loss, corruption, duplication, and reordering.
# - Rollback to original network conditions.
#
# Copyright (C) 2023 Haytham Elkhoja
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# Define global variables
ifb0_interface="ifb0"
ifb1_interface="ifb1"
selected_interface=""
interface_provided=0
rollback_required=0
rollback_done=0
num_pings=5

# Helper function to handle failures
die() {
    echo -e "$1" >&2
    exit 1
}

check_root() {
    if [ $(id -u) -ne 0 ]; then
       echo -e "\e[31mThis script must be run as root or with sudo privileges\e[0m" 1>&2
       exit 1
    fi
}

# Check for necessary Debian/Ubuntu packages
check_debian_packages() {
    local required_packages=("iproute2")
    local cmd=("dpkg-query" "-W" "-f=${Status}")
    check_missing_packages cmd "install ok installed" "${required_packages[@]}"
}
# Check for necessary CentOS/Fedora/RHEL packages
check_redhat_packages() {
    local required_packages=("iproute" "kernel-modules-extra" "iproute-tc")
    local cmd=("rpm" "-q")
    check_missing_packages cmd "" "${required_packages[@]}"
}

# Check for missing packages
check_missing_packages() {
    local -n check_command_array=$1
    local success_string="$2"
    shift 2
    local packages=("$@")
    
    local missing_packages=()

    for package in "${packages[@]}"; do
        if [ -z "$success_string" ]; then
            # Just look for the package name if success_string is empty
            if ! "${check_command_array[@]}" "$package" >/dev/null 2>&1; then
                missing_packages+=("$package")
            fi
        else
            if ! "${check_command_array[@]}" "$package" 2>/dev/null | grep -q "$success_string"; then
                missing_packages+=("$package")
            fi
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        case $OS in
            debian|ubuntu)
                die "The following packages are missing: ${missing_packages[*]}.\nPlease install them using 'sudo apt install ${missing_packages[*]}' and retry."
                ;;
            centos|fedora|rhel)
                die "The following packages are missing: ${missing_packages[*]}.\nPlease install them using 'sudo dnf install ${missing_packages[*]}' and retry."
                ;;
            *)
                die "The following packages are missing: ${missing_packages[*]}.\nPlease install and retry."
                ;;
        esac
    fi
}

# Check for packages
check_packages() {
    # Detect the OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        die "Cannot identify OS type."
    fi
    
    case $OS in
        debian|ubuntu)
            check_debian_packages
            ;;
        centos|fedora|rhel)
            check_redhat_packages
            ;;
        *)
            die "Unsupported OS type. Run this script on CentOS/Fedora/RHEL and Debian/Ubuntu systems."
            ;;
    esac
}

# Load the ifb module
load_ifb_module() {
    modprobe ifb || die "Failed to load the ifb module."
}

# Create virtual interfaces if they doesn't exist
create_virtual_interface() {
    local interface="$1"
    ip link show "$interface" &>/dev/null || ip link add "$interface" type ifb
}

# Bring up the interfaces
bring_up_interface() {
    local interface="$1"
    ip link set dev "$interface" up || die "Failed to bring up $interface."
}

# Function to delete existing qdisc if it exists
delete_qdisc_if_exists() {
    local interface="$1"
    local qdisc_type="$2"
    local handle="$3"
    if tc qdisc show dev "$interface" | grep -qw "$handle"; then
        tc qdisc del dev "$interface" $qdisc_type 2>/dev/null || {
            echo -e "\e[31mFailed to remove existing qdisc on $interface.\e[0m" >&2
            rollback_everything
            exit 1
        }
    fi
}

# Function to roll back network perturbations changes
rollback_everything() {
    if [ "$rollback_required" -eq 1 ] && [ "$rollback_done" -eq 0 ]; then
        echo "Rolling back network perturbations changes..."        
        tc qdisc del dev "$selected_interface" ingress 2>/dev/null
        tc qdisc del dev "$selected_interface" root 2>/dev/null
        tc qdisc del dev "$ifb0_interface" root 2>/dev/null
        tc qdisc del dev "$ifb1_interface" root 2>/dev/null

        # Set down the virtual interfaces
        ip link delete dev "$ifb0_interface" down 2>/dev/null
        ip link delete dev "$ifb1_interface" down 2>/dev/null
        rollback_done=1
    fi
}

# Display usage information
usage() {
    echo 
    echo "Latency Ninja v0.1alpha"
    echo "Author: Haytham Elkhoja - haytham@elkhoja.com"
    echo
    echo "This script is designed to emulate network perturbations, allowing you to introduce egress and ingress latency "
    echo "jitter,  packet loss and moreon specific interfaces for a specific destination IP addresses. This program is distributed " 
    echo "in the hope that it will be useful, but WITHOUT ANY WARRANTY."
    echo 
    echo "Usage: $0 -i <interface> -d <destination_ip> -l <latency> -j <jitter> [-p <num_pings>]"
    echo
    echo "Arguments:"
    echo "  -h                    Display this help message."
    echo "  -r                    Rollback any networking conditions changes and redirections."
    echo "  -i <interface>        Network interface (e.g., eth0)."
    echo "  -d <destination_ip>   Destination IP address."
    echo "  -l <latency>          Desired latency in milliseconds (e.g., 30)."
    echo "  -j <jitter>           Desired jitter in milliseconds (e.g., 3)."
    echo "  -x <packet_loss>      Desired packet loss percentage (e.g., 2 for 2%)."
    echo "  -y <duplicate>        Desired duplicate packet percentage (e.g., 2 for 2%)."
    echo "  -z <corrupt>          Desired corrupted packet percentage (e.g., 1 for 1%)."
    echo "  -k <reorder>          Desired packet reordering percentage (e.g., 1 for 1%)."
    echo "  -p <num_pings>        Number of pings for the test (default: 5)."  
    echo
}

validate_arguments() {
    # Check if any options were provided
    if [ $# -eq 0 ]; then
        usage
        die "No options provided. See usage above."
    fi

    while getopts ":hri:d:l:j:p:x:y:z:k:" opt; do
        case $opt in
            h)
                usage
                exit 0
                ;;
            r)
                rollback_required=1
                ;;
            i)
                selected_interface="$OPTARG"
                interface_provided=1
                ;;
            d)
                destination_ip="$OPTARG"
                ;;
            l)
                latency="$OPTARG"
                ;;
            j)
                jitter="$OPTARG"
                ;;
            p)
                num_pings="$OPTARG"
                ;;
            x)
                packet_loss="$OPTARG"
                ;;
            y)
                duplicate="$OPTARG"
                ;;
            z)
                corrupt="$OPTARG"
                ;;
            k)
                reorder="$OPTARG"
                ;;
            \?)
                die "Invalid option: -$OPTARG"
                ;;
            :)
                die "Option -$OPTARG requires an argument."
                ;;
        esac
    done
}

parse_arguments(){
    # Check for rollback after parsing all options
    if [ "$rollback_required" -eq 1 ]; then
        if [ "$interface_provided" -eq 0 ]; then
            echo "The -r option requires the -i option with a valid interface."
            exit 1
        else
            rollback_everything
            echo "Rolled back network perturbations changes for interface $selected_interface."
            exit 0
        fi
    fi

    # Validate that interface and destination IP are provided
    if [ -z "$selected_interface" ] || [ -z "$destination_ip" ]; then
        usage
        die "Interface and destination IP options are mandatory. See usage above."
    fi

    # Check if at least one of the other parameters is defined
    if [ -z "$latency" ] && [ -z "$jitter" ] && [ -z "$corruption" ] && [ -z "$duplication" ] && [ -z "$reorder" ] && [ -z "$packet_loss" ]; then
        usage
        die "At least one of the parameters (latency, jitter, corruption, duplication, reorder, packet_loss) must be provided. See usage above."
    fi

    # Validate the selected interface
    interfaces=$(ip -o link show | awk -F ': ' '{print $2}' | grep -v "lo")
    if ! echo "$interfaces" | grep -wq "$selected_interface"; then
        die "Invalid interface selected. Please choose a valid network interface."
    fi

    [ -n "$latency" ] && [[ ! "$latency" =~ ^[0-9]+$ ]] && die "Invalid packet loss format. Please use a numeric value."
    [ -n "$jitter" ] && [[ ! "$jitter" =~ ^[0-9]+$ ]] && die "Invalid packet loss format. Please use a numeric value."
    [ -n "$num_pings" ] && [[ ! "$num_pings" =~ ^[0-9]+$ ]] && die "Invalid packet loss format. Please use a numeric value."
    [ -n "$packet_loss" ] && [[ ! "$packet_loss" =~ ^[0-9]+$ ]] && die "Invalid packet loss format. Please use a numeric value."
    [ -n "$duplicate" ] && [[ ! "$duplicate" =~ ^[0-9]+$ ]] && die "Invalid duplicate packet format. Please use a numeric value."
    [ -n "$corrupt" ] && [[ ! "$corrupt" =~ ^[0-9]+$ ]] && die "Invalid corrupted packet format. Please use a numeric value."
    [ -n "$reorder" ] && [[ ! "$reorder" =~ ^[0-9]+$ ]] && die "Invalid packet reordering format. Please use a numeric value."
}

# Function to ping the destination and display the result
ping_destination() {
    local host="$1"

    # Run the ping command in a subshell with its own trap
    (
        trap 'exit 130' SIGINT
        ping -c "$num_pings" "$host"
    )
    
    # Check if ping was interrupted by SIGINT and if so, handle it
    if [ $? -eq 130 ]; then
        rollback_everything
        exit 1
    fi
}

display_ping_process() {
    local stage="$1" # Should be 'before' or 'after'
    local host="$2"

    echo "Pinging the destination $stage applying network perturbation:"
    ping_destination "$host"
    echo
}

display_apply_params() {
    echo "Applying network perturbations with the following parameters:"
    echo "  - Interface: $selected_interface"
    echo "  - Destination IP: $destination_ip"
    
    # Check each parameter and display if defined
    [ -n "$latency" ] && echo "  - Latency: $latency ms"
    [ -n "$jitter" ] && echo "  - Jitter: $jitter ms"
    [ -n "$corruption" ] && echo "  - Corruption: $corruption%"
    [ -n "$duplication" ] && echo "  - Duplication: $duplication%"
    [ -n "$reorder" ] && echo "  - Reorder: $reorder%"
    [ -n "$packet_loss" ] && echo "  - Packet Loss: $packet_loss%"
    
    echo
}

display_after_message() {
    echo "Network perturbations applied for ingress and egress traffic between $source_ip and $destination_ip on interface $selected_interface."
    
    # Check each parameter and display if defined
    [ -n "$latency" ] && echo "  - Latency: $latency ms"
    [ -n "$jitter" ] && echo "  - Jitter: $jitter ms"
    [ -n "$corruption" ] && echo "  - Corruption: $corruption%"
    [ -n "$duplication" ] && echo "  - Duplication: $duplication%"
    [ -n "$reorder" ] && echo "  - Reorder: $reorder%"
    [ -n "$packet_loss" ] && echo "  - Packet Loss: $packet_loss%"
    
    echo
    echo "To rollback, run $0 -r -i $selected_interface"
    echo 
}

pinging_before(){
    display_ping_process "before" "$destination_ip"
    display_apply_params
}

pinging_after(){
    display_ping_process "after" "$destination_ip"
    display_after_message
}

# Function to validate numeric values
validate_numeric_format() {
    local value="$1"
    local name="$2"

    if [ ! "$value" -eq "$value" ] 2>/dev/null || [ ! "$value" -ge 0 -a "$value" -le 9999 ]; then
        usage
        die "Invalid $name format. Please use a numeric value (e.g., 30) for $name."
    fi
}

configure_traffic_controls() {

    # Redirect ingress traffic to ifb0
    delete_qdisc_if_exists "$selected_interface" "ingress" "ffff: ingress"
    tc qdisc add dev "$selected_interface" handle ffff: ingress || die "Failed to set up ingress qdisc."
    tc filter add dev "$selected_interface" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb0_interface" || die "Failed to redirect incoming traffic to $ifb0_interface."
    rollback_required=1

    # Redirect egress traffic to ifb1
    delete_qdisc_if_exists "$selected_interface" "root" "1: prio"
    tc qdisc add dev "$selected_interface" root handle 1: prio || die "Failed to add egress qdisc."
    tc filter add dev "$selected_interface" parent 1: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb1_interface" || die "Failed to redirect outgoing traffic to $ifb1_interface."

    # Retrieve the source IP address from the system
    source_ip=$(ip addr show dev "$selected_interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

    # Validate latency, jitter, corruption, duplication, etc.
    [ -n "$latency" ] && validate_numeric_format "$latency" "latency"
    [ -n "$jitter" ] && validate_numeric_format "$jitter" "jitter"
    [ -n "$corruption" ] && validate_numeric_format "$corruption" "corruption"
    [ -n "$duplication" ] && validate_numeric_format "$duplication" "duplication"
    [ -n "$reorder" ] && validate_numeric_format "$reorder" "reorder"
    [ -n "$packet_loss" ] && validate_numeric_format "$packet_loss" "packet_loss"

    # Compute the half-latency if latency is applied
    if [ ! -z "$latency" ]; then
        half_latency=$(($latency / 2))
    else
        half_latency=0
    fi

    # Compute the half-jitter if jitter is applied
    if [ ! -z "$jitter" ]; then
        half_jitter=$(($jitter / 2))
    else
        half_jitter=0
    fi

    # Modify the netem command based on the new options
    local netem_params=""
    [ -n "$latency" ] && [ -n "$jitter" ] && netem_params="delay ${half_latency}ms ${half_jitter}ms"
    [ -n "$packet_loss" ] && netem_params="$netem_params loss $packet_loss%"
    [ -n "$duplicate" ] && netem_params="$netem_params duplicate $duplicate%"
    [ -n "$corrupt" ] && netem_params="$netem_params corrupt $corrupt%"
    [ -n "$reorder" ] && netem_params="$netem_params reorder $reorder%"

    # Apply delay to ingress (incoming) traffic on ifb0 for specific IP addresses
    delete_qdisc_if_exists "$ifb0_interface" "root" "1: prio"
    tc qdisc add dev "$ifb0_interface" root handle 1: prio || die "Failed to add ingress qdisc."
    tc filter add dev "$ifb0_interface" parent 1: protocol ip prio 1 u32 match ip src "$destination_ip" flowid 1:1 || die "Failed to add ingress filter."
    tc qdisc add dev "$ifb0_interface" parent 1:1 handle 2: netem $netem_params || die "Failed to add ingress delay and other parameters."    

    # Apply delay to egress (outgoing) traffic on ifb1 for specific IP addresses
    delete_qdisc_if_exists "$ifb1_interface" "root" "1: prio"
    tc qdisc add dev "$ifb1_interface" root handle 1: prio || die "Failed to add egress qdisc on $ifb1_interface."
    tc filter add dev "$ifb1_interface" parent 1: protocol ip prio 1 u32 match ip src "$source_ip" match ip dst "$destination_ip" flowid 1:1 || die "Failed to add egress filter on $ifb1_interface."
    tc qdisc add dev "$ifb1_interface" parent 1:1 handle 2: netem $netem_params || die "Failed to add egress delay and other parameters."
}

main() {
    check_root
    check_packages
    validate_arguments "$@"
    parse_arguments
    load_ifb_module
    create_virtual_interface "$ifb0_interface"
    create_virtual_interface "$ifb1_interface"
    bring_up_interface "$ifb0_interface"
    bring_up_interface "$ifb1_interface"
    pinging_before
    configure_traffic_controls
    pinging_after
}

main "$@"

trap - INT TERM

