#!/usr/bin/env bash

# Latency Ninja
#
# Latency Ninja is a wrapper tool for tc/netem to simulate network perturbations by applying latency, jitter, packet loss, and more.
#
# Copyright (C) 2023 
# Haytham Elkhoja
# Mike Lyons
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

# Define current version
app_name="Lazy Ninja"
current_version="1.3"

# Define global variables
ifb0_interface="ifb0"
ifb1_interface="ifb1"
selected_interface=""
src_ip=""
dst_ip=""
latency=""
jitter=""
packet_loss=""
duplicate=""
corrupt=""
reorder=""
direction="both" # Both is always selected by default
interface_provided=0
jitter_provided=0
latency_provided=0
rollback_required=0
rollback_done=0
num_pings=5
DEBUG=false

# Function to handle failures with debug options
die() {
    local exit_code=$?
    local script_name=${BASH_SOURCE[1]}
    local line_number=${BASH_LINENO[0]}
    local function_name=${FUNCNAME[1]}
    local message="$@"

    if $DEBUG; then
        # Detailed error information for debugging
        echo
        printf "[%s v%s] Debug Error: Function %s at line %s of %s with message:\n%s\n" "$app_name" "$current_version" "$function_name" "$line_number" "$script_name" "$message"
    else
        # Basic error information
        printf "Error: %s \n" "$message"
    fi

    if [[ -n "$rollback_required" ]]; then
        rollback_everything
        echo "Try again."
    fi

    exit $exit_code
}

# Function to check full paths of commands
 find_command_paths() {    
    TC_PATH=$(which tc 2>/dev/null)
    PING_PATH=$(which ping 2>/dev/null)
    IP_PATH=$(which ip 2>/dev/null)
    MODPROBE_PATH=$(which modprobe 2>/dev/null)
}

# Function to check for root/sudo privileges
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo
        echo -e "This script must be run as root or with sudo privileges." 1>&2
        exit 1
    fi
}

# Function to check for necessary Debian/Ubuntu packages
check_debian_packages() {
    local required_packages=("kmod" "iproute2")
    local cmd=("/usr/bin/dpkg-query" "-W" "-f=${Status}")
    check_missing_packages cmd "install ok installed" "${required_packages[@]}"
}

# Function to check for necessary CentOS/Fedora/RHEL packages
check_redhat_packages() {
    local required_packages=("kmod" "iproute" "kernel-modules-extra" "iproute-tc")
    local cmd=("/usr/bin/rpm" "-q")
    check_missing_packages cmd "" "${required_packages[@]}"
}

# Function to check for missing packages
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
                die "The following packages are missing: ${missing_packages[*]}. Please install them using 'sudo apt install ${missing_packages[*]}' and retry."
                ;;
            centos|fedora|rhel)
                die "The following packages are missing: ${missing_packages[*]}. Please install them using 'sudo dnf install ${missing_packages[*]}' and retry."
                ;;
            *)
                die "The following packages are missing: ${missing_packages[*]}. Please install and retry."
                ;;
        esac
    fi
}

# Function to check for packages
detect_os_check_packages() {
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

# Function to load the ifb module
load_ifb_module() {
    $MODPROBE_PATH ifb || die "Failed to load the ifb module."
}

# Function to create virtual interfaces if they doesn't exist
create_virtual_interface() {
    local interface="$1"
    $IP_PATH link add "$interface" type ifb || die "Failed to create $interface."
}

# Function to bring up the interfaces
bring_up_interface() {
    local interface="$1"
    $IP_PATH link set dev "$interface" up || die "Failed to bring up $interface."
}

# Function to delete existing qdisc if it exists
delete_qdisc_if_exists() {
    local interface="$1"
    local qdisc_type="$2"
    local handle="$3"
    if $TC_PATH qdisc show dev "$interface" | grep -qw "$handle"; then
        $TC_PATH qdisc del dev "$interface" "$qdisc_type" 2>/dev/null || {
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
        $TC_PATH qdisc del dev "$selected_interface" ingress 2>/dev/null
        $TC_PATH qdisc del dev "$selected_interface" root 2>/dev/null
        $TC_PATH qdisc del dev "$ifb0_interface" root 2>/dev/null
        $TC_PATH qdisc del dev "$ifb1_interface" root 2>/dev/null

        # Set down the virtual interfaces
        $IP_PATH link delete dev "$ifb0_interface" 2>/dev/null
        $IP_PATH link delete dev "$ifb1_interface" 2>/dev/null
        rollback_done=1
    fi
}

# Function to display usage information
usage() {
    echo 
    echo "Latency Ninja $current_version"
    echo
    echo "This script is designed to emulate network perturbations, allowing you to introduce egress and ingress latency,"
    echo "jitter, packet loss, and more on specific interfaces for a specific destination IP address or Network. This program is distributed" 
    echo "in the hope that it will be useful, but WITHOUT ANY WARRANTY."
    echo 
    echo "Usage: $0 -h -r -i <interface> -s <source_ip/network> -d <destination_ip/network> "
    echo "             [-l <latency>] [-j <jitter>] [-x <packet_loss>] [-y <duplicate>] "
    echo "             [-z <corrupt>] [-k <reorder>] [-p <num_pings>]"
    echo
    echo "Options:"
    echo "  -h, --help                                              Display this help message."
    echo "  -r, --rollback                                          Rollback any networking conditions changes and redirections."
    echo
    echo "  -i, --interface <interface>                             Desired Network interface (e.g., eth0)."
    echo "  -s, --src_ip <source_ip>                                Desired Source IP/Network. (default: IP of selected interface)"    
    echo "  -d, --dst_ip <destination_ip[,destination_ip2,...]>     Desired Destination IP(s)/Network(s)."
    echo "  -w, --direction <direction>                             Desired direction of the networking conditions (ingress, egress, or both) (default: both)"
    echo  
    echo "  -l, --latency <latency>                                 Desired latency in milliseconds (e.g., 30 for 30ms)."
    echo "  -j, --jitter <jitter>                                   Desired jitter in milliseconds (e.g., 3 for 3ms). Use with -l|--latency only."
    echo "  -x, --packet-loss <packet_loss>                         Desired packet loss percentage ((e.g., 2 for 2% or 0.9 for 0.9%).."    
    echo "  -y, --duplicate <duplicate>                             Desired duplicate packet percentage (e.g., 2 for 2% or 0.9 for 0.9%).."
    echo "  -z, --corrupt <corrupt>                                 Desired corrupted packet percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    echo "  -k, --reorder <reorder>                                 Desired packet reordering percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    echo "  -p, --pings <num_pings>                                 Desired number of pings to test (default: 5)."  
    echo
}

# Function to validate arguments given in latencyninja.sh 
validate_arguments() {
    # Check if any options were provided
    if [ $# -eq 0 ]; then
        usage
        die "No options provided. See usage above."
    fi

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --debug)
                # Handle the --debug option (no argument) and exit.            
                DEBUG=true
                shift
                ;;  
            -h|--help)
                # Handle the -h or --help option (no argument) and exit.
                usage
                exit 0
                ;;           
            -r|--rollback)
                # Handle the -r or --rollback option (no argument).
                rollback_required=1
                shift 1  
                ;;        
            -i|--interface)
                # Handle the -i or --interface option with an argument.
                selected_interface="$2"
                interface_provided=1
                shift 2
                ;;
            -s|--src_ip)
                # Handle the -s or --src_ip option with an argument.
                src_ip="$2"
                shift 2
                ;;
            -d|--dst_ip)
                # Handle the -d or --dst_ip option with an argument.
                IFS=',' read -ra dst_ip <<< "$2"
                shift 2
                ;;            
            -w|--direction)
                # Handle the -w or --direction option with an argument.
                direction="$2"
                shift 2
                ;;                
            -l|--latency)
                # Handle the -l or --latency option with an argument.
                latency="$2"
                latency_provided=1
                shift 2
                ;;
            -j|--jitter)
                # Handle the -j or --jitter option with an argument.
                jitter="$2"
                jitter_provided=1
                shift 2
                ;;
            -x|--packet-loss)
                # Handle the -x or --packet-loss option with an argument.
                packet_loss="$2"
                shift 2
                ;;
            -y|--duplicate)
                # Handle the -y or --duplicate option with an argument.
                duplicate="$2"
                shift 2
                ;;
            -z|--corrupt)
                # Handle the -z or --corrupt option with an argument.
                corrupt="$2"
                shift 2
                ;;
            -k|--reorder)
                # Handle the -k or --reorder option with an argument.
                reorder="$2"
                shift 2
                ;;
            -p|--pings)
                # Handle the -p or --pings option with an argument.
                num_pings="$2"
                shift 2
                ;;                
            *)
                # Handle unknown or invalid options here and exit.
                echo "Invalid option: $1"
                exit 1
                ;;
        esac
    done
}

# Function to parse arguments provided with latency_ninja.sh
parse_arguments(){
    if [ "$rollback_required" -eq 1 ]; then
        if [ "$interface_provided" -eq 0 ]; then
            echo "The -r|--rollback option requires the -i|--interface option with a valid interface."
            exit 1
        else
            rollback_everything
            echo "Rolled back network perturbations changes for interface $selected_interface."
            exit 0
        fi
    fi

    # Set $src_ip if not provided
    if [ -z "$src_ip" ];then
        src_ip=$($IP_PATH -o -4 address show dev "$selected_interface" | awk '{print $4}' | cut -d'/' -f1)
    fi

    # Validate that interface, destination IP, source IP, and direction are provided
    if [ -z "$selected_interface" ] || [ -z "$src_ip" ] || [ "${#dst_ip[@]}" -eq 0 ] || [ -z "$direction" ]; then
        die "Interface and destination IP/network options are mandatory. Use --help for usage information."
    fi

    # Check if at least one of the other parameters is defined
    if [ -z "$latency" ] && [ -z "$jitter" ] && [ -z "$duplicate" ]  && [ -z "$corrupt" ]&& [ -z "$reorder" ] && [ -z "$packet_loss" ]; then
        die "At least one of the parameters (latency, jitter, duplicate, corrupt, reorder, packet_loss) must be provided. Use --help for usage information."
    fi

    # Validate the selected interface
    interfaces=$($IP_PATH -o link show | awk -F ': ' '{print $2}' | grep -v "lo")
    if ! echo "$interfaces" | grep -wq "$selected_interface"; then
        die "Invalid interface selected. Please choose a valid network interface."
    fi 

    if [ "$latency_provided" -eq 0 ] && [ "$jitter_provided" -eq 1 ]; then
        die "Jitter can only be used with latency. Use --help for usage information."
    fi

    # Validate src_ip, dist_ip, latency, jitter, duplicate, corrupt, reorder, packet_loss.
    [ -n "$src_ip" ] && validate_ip_format "$src_ip" "src_ip"
    for dip in "${dst_ip[@]}"; do
        [ -n "$dip" ] && validate_ip_format "$dip" "dst_ip"
    done
    [ -n "$latency" ] && latency=$(validate_numeric_format "$latency" "latency")
    [ -n "$jitter" ] && jitter=$(validate_numeric_format "$jitter" "jitter")
    [ -n "$packet_loss" ] && packet_loss=$(validate_numeric_format "$packet_loss" "packet_loss")    
    [ -n "$duplicate" ] && duplicate=$(validate_numeric_format "$duplicate" "duplicate")
    [ -n "$corrupt" ] && corrupt=$(validate_numeric_format "$corrupt" "corrupt")
    [ -n "$reorder" ] && reorder=$(validate_numeric_format "$reorder" "reorder")    

}

# Function to ping the destination and display the result (skipped for networks)
ping_destination() {
    local host="$1"

    # Check if the destination is a single host IP or a network
    if [[ "$host" == *"/"* ]]; then
        local ip_part="${host%%/*}"
        local subnet_mask="${host#*/}"
        IFS='.' read -r -a ip_octets <<< "$ip_part"

        # Check if subnet mask is valid (0-32 for IPv4)
        if [[ "$subnet_mask" =~ ^[0-9]+$ ]] && ((subnet_mask >= 0 && subnet_mask <= 32)); then
            # If it has more than 1 octet or a subnet mask other than /32, it's a network
            if [[ ${#ip_octets[@]} -gt 1 || "$subnet_mask" != "32" ]]; then
                echo "Skipping ping for network '$host'. Pinging is only supported for single host IP address."
                return
            fi
        fi
    fi

    # Run the ping command in a subshell with its own trap
    (
        trap 'exit 130' SIGINT
        $PING_PATH -c "$num_pings" "$host"
    )
    
    # Check if ping was interrupted by SIGINT and if so, handle it
    if [ $? -eq 130 ]; then
        rollback_everything
        exit 1
    fi
}

# Function to display ping process
display_ping_process() {
    local stage="$1" # Should be 'before' or 'after'
    local hosts=("${@:2}") # All arguments after the first one are considered as hosts

    for host in "${hosts[@]}"; do
        echo "Pinging the destination $stage applying network perturbations for host $host:"
        ping_destination "$host"
        echo
    done
}

# Function to ping pre/post network perturbations
pinging() {
    local stage="$1"  # "before" or "after"
    local hosts=("${@:2}") # All arguments after the first one are considered as hosts

    display_ping_process "$stage" "${hosts[@]}"

    if [ "$stage" == "before" ]; then
        display_apply_params
    elif [ "$stage" == "after" ]; then
        display_after_message
    else
        die "Invalid stage: $stage. Use 'before' or 'after'."
    fi
}

# Function to display parameters that will be applied
display_apply_params() {
    echo "Applying network perturbations on:"
    echo "  - Interface: $selected_interface"
    echo "  - Source IP/Network: $src_ip"
    echo
}

# Function to display results
display_after_message() {
    echo "Network perturbations applied with the following parameters:" 
    [ -n "$selected_interface" ] && echo "  - Interface: $selected_interface"   
    [ -n "$src_ip" ] && echo "  - Source IP/Network: $src_ip"   
    for dip in "${dst_ip[@]}"; do
        [ -n "$dip" ] && echo "  - Destination IP/Network: $dip"       
    done    
    [ -n "$direction" ] && echo "  - Direction: $direction"   
    [ -n "$latency" ] && echo "  - Latency: $latency ms"
    [ -n "$jitter" ] && echo "  - Jitter: $jitter ms"
    [ -n "$packet_loss" ] && echo "  - Packet Loss: $packet_loss%"     
    [ -n "$duplicate" ] && echo "  - Duplication: $duplicate%"    
    [ -n "$corrupt" ] && echo "  - Corruption: $corrupt%"
    [ -n "$reorder" ] && echo "  - Reorder: $reorder%"
    
    echo
    echo "To rollback, run $0 --rollback --interface $selected_interface"
    echo 
}

# Function to validate numeric values
validate_numeric_format() {
    local original_value="$1"
    local name="$2"

    # Remove all characters that are not digits or decimal points
    local value=${original_value//[^0-9.]/}

    if ! [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        die "Invalid $name format. Please use a positive numeric value (e.g., 1 for 1ms or 0.9 for 0.9%) for $name."
    elif (( $(bc <<< "$value <= 0") )); then
        die "Invalid $name format. Please provide a positive numeric value."
    fi

    echo $value
}


# Function to validate IP addresses or IP networks
validate_ip_format() {
    local value="$1"
    local name="$2"

    if ! [[ "$value" =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)((/([0-2]?[0-9]|3[0-2]))?)$ ]]; then
        die "Invalid $name format. Please use a valid IPv4 address or CIDR notation IPv4 network for $name."
    fi
}

# Function for configuring ingress traffic controls
configure_ingress_traffic_controls() {
    local selected_interface="$1"
    local ifb1_interface="$2"
    local src_ip="$3"
    local dst_ip=("${!4}")  # Receive dst_ip as an array
    local latency="$5"
    local jitter="$6"
    local packet_loss="$7"
    local duplicate="$8"
    local corrupt="$9"
    local reorder="${10}"

    # Check if direction is "both" and calculate half-latency and half-jitter
    if [ "$direction" == "both" ]; then
        if [ -n "$latency" ]; then
            latency=$(awk "BEGIN {print $latency / 2}")
        fi       
        if [ -n "$jitter" ]; then
            jitter=$(awk "BEGIN {print $jitter / 2}")
        fi
    fi
    
    # Redirect ingress traffic to ifb0
    delete_qdisc_if_exists "$selected_interface" "ingress" "ffff: ingress"
    $TC_PATH qdisc add dev "$selected_interface" handle ffff: ingress || die "Failed to set up ingress qdisc for $selected_interface."
    $TC_PATH filter add dev "$selected_interface" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb0_interface" || die "Failed to redirect incoming traffic to $ifb0_interface."

    # Modify the netem command based on the new options
    local netem_params=""
    [ -n "$latency" ] && netem_params="delay ${latency}ms"
    [ -n "$jitter" ] && netem_params="$netem_params ${jitter}ms"
    [ -n "$packet_loss" ] && netem_params="$netem_params loss $packet_loss%"
    [ -n "$duplicate" ] && netem_params="$netem_params duplicate $duplicate%"
    [ -n "$corrupt" ] && netem_params="$netem_params corrupt $corrupt%"
    [ -n "$reorder" ] && netem_params="$netem_params reorder $reorder%"
    
    # Apply delay to ingress (incoming) traffic on ifb0 for specific IP addresses (swtiching the order of $dist_ip and $src_ip as this is ingress)
    delete_qdisc_if_exists "$ifb0_interface" "root" "1: prio"
    $TC_PATH qdisc add dev "$ifb0_interface" root handle 1: prio || die "Failed to add ingress qdisc for $selected_interface."    
    for dip in "${dst_ip[@]}"; do
        $TC_PATH filter add dev "$ifb0_interface" parent 1: protocol ip prio 1 u32 match ip src "$dip" match ip dst "$src_ip" flowid 1:1 || die "Failed to add egress filter on $ifb0_interface for $dip to $src_ip."
    done
    $TC_PATH qdisc add dev "$ifb0_interface" parent 1:1 handle 2: netem $netem_params || die "Failed to add ingress network perturbations."    
}

# Function for configuring egress traffic controls
configure_egress_traffic_controls() {
    local selected_interface="$1"
    local ifb1_interface="$2"
    local src_ip="$3"
    local dst_ip=("${!4}")  # Receive dst_ip as an array
    local latency="$5"
    local latency="$5"
    local jitter="$6"
    local packet_loss="$7"
    local duplicate="$8"
    local corrupt="$9"
    local reorder="${10}"

    # Check if direction is "both" and calculate half-latency and half-jitter
    if [ "$direction" == "both" ]; then
        if [ -n "$latency" ]; then
            latency=$(awk "BEGIN {print $latency / 2}")
        fi        
        if [ -n "$jitter" ]; then
            jitter=$(awk "BEGIN {print $jitter / 2}")
        fi
    fi

    # Redirect egress traffic to ifb1
    delete_qdisc_if_exists "$selected_interface" "root" "1: prio"
    $TC_PATH qdisc add dev "$selected_interface" root handle 1: prio || die "Failed to add egress qdisc for $selected_interface."
    $TC_PATH filter add dev "$selected_interface" parent 1: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb1_interface" || die "Failed to redirect outgoing traffic to $ifb1_interface."

    # Modify the netem command based on the new options    
    local netem_params=""
    [ -n "$latency" ] && netem_params="delay ${latency}ms"
    [ -n "$jitter" ] && netem_params="$netem_params ${jitter}ms"
    [ -n "$packet_loss" ] && netem_params="$netem_params loss $packet_loss%"
    [ -n "$duplicate" ] && netem_params="$netem_params duplicate $duplicate%"
    [ -n "$corrupt" ] && netem_params="$netem_params corrupt $corrupt%"
    [ -n "$reorder" ] && netem_params="$netem_params reorder $reorder%"

    # Apply delay to egress (outgoing) traffic on ifb1 for specific IP addresses
    delete_qdisc_if_exists "$ifb1_interface" "root" "1: prio"
    $TC_PATH qdisc add dev "$ifb1_interface" root handle 1: prio || die "Failed to add egress qdisc on $ifb1_interface."
    for dip in "${dst_ip[@]}"; do
        $TC_PATH filter add dev "$ifb1_interface" parent 1: protocol ip prio 1 u32 match ip src "$src_ip" match ip dst "$dip" flowid 1:1 || die "Failed to add egress filter on $ifb1_interface for $src_ip to $dip."
    done
    $TC_PATH qdisc add dev "$ifb1_interface" parent 1:1 handle 2: netem $netem_params || die "Failed to add egress network perturbations."
}

main() {
    find_command_paths
    validate_arguments "$@"
    parse_arguments
    check_root
    detect_os_check_packages
    rollback_required=1
    load_ifb_module
    pinging "before" "${dst_ip[@]}"
    if [ "$direction" == "ingress" ] || [ "$direction" == "both" ]; then
        create_virtual_interface "$ifb0_interface"
        bring_up_interface "$ifb0_interface"
        configure_ingress_traffic_controls "$selected_interface" "$ifb0_interface" "$src_ip" dst_ip[@] "$latency" "$jitter" "$packet_loss" "$duplicate" "$corrupt" "$reorder"
    fi
    if [ "$direction" == "egress" ] || [ "$direction" == "both" ]; then
        create_virtual_interface "$ifb1_interface"
        bring_up_interface "$ifb1_interface"        
        configure_egress_traffic_controls "$selected_interface" "$ifb1_interface" "$src_ip" dst_ip[@] "$latency" "$jitter" "$packet_loss" "$duplicate" "$corrupt" "$reorder"
    fi
    pinging "after" "${dst_ip[@]}"
}

main "$@"

trap - INT TERM
