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

# Function to validate arguments given
get_arguments() {
    if [ $# -eq 0 ]; then
        usage
    fi

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -a|--about) about; exit 0 ;;
            -q|--query) query; exit 0 ;; 
            --debug) debug=true; shift ;;
            --update) update; shift ;;
            -r|--rollback) rollback_required=1; shift;;
            -i|--interface) process_arg eth_interface interface_provided "$@"; shift 2 ;;
            -s|--src_ip) process_arg validate_src_ip "" "$@"; shift 2 ;;
            -d|--dst_ip) process_arg validate_dst_ip "" "$@"; shift 2 ;;
            -w|--direction) process_arg direction "" "$@"; shift 2 ;;
            -l|--latency) process_arg latency latency_provided "$@"; shift 2 ;;
            -j|--jitter) process_arg jitter jitter_provided "$@"; shift 2 ;;
            -x|--packet_loss) process_arg packet_loss "" "$@"; shift 2 ;;
            -y|--duplicate) process_arg duplicate "" "$@"; shift 2 ;;
            -z|--corrupt) process_arg corrupt "" "$@"; shift 2 ;;
            -k|--reorder) process_arg reorder "" "$@"; shift 2 ;;
            *) echo "Invalid option: $1"; exit 1 ;;
        esac
    done
}

# Function to validate arguments given
process_arg() {
    local var_name="$1"
    local flag_name="$2"
    shift 2
    if [[ -z "$2" || "$2" == -* ]]; then
        die "The -$1 option requires an argument."
    else
        if [[ -n "$flag_name" ]]; then
            declare -g "$flag_name=1"
        fi
        if [[ "$var_name" == validate_* ]]; then
            "$var_name" "$2"
        else
            declare -g "$var_name=$2"
        fi
    fi
}

# Function to parse arguments
parse_arguments() {
    # Validate the selected interface
    if ! ip link show "$eth_interface" &>/dev/null; then
        die "Invalid interface: $eth_interface. Please provide a valid network interface."
    fi

    # Check thet -r is used with -i
    if [ "$rollback_required" -eq 1 ]; then
        if [ "$interface_provided" -eq 0 ]; then
            die "The -r|--rollback option requires the -i|--interface option."
        else
            rollback_everything
            echo -e "\nRolled back network perturbations changes for interface $eth_interface."
            exit 0
        fi
    fi
    
    local_ip=$($ip_path -o -4 address show dev "$eth_interface" | awk '{print $4}' | cut -d'/' -f1):0
    
    # If src_ip is provided but dst_ip is not, set dst_ip to local_ip
    if [ "${#src_ip[@]}" -gt 0 ] && [ "${#dst_ip[@]}" -eq 0 ]; then
        dst_ip=("$local_ip")  # Assign as an array
    fi

    # If src_ip is not provided, set it to local_ip
    if [ "${#src_ip[@]}" -eq 0 ]; then
         src_ip=("$local_ip")  # Assign as an array
    fi

    # Validate mandatory parameters
    [ -z "$eth_interface" ] || [ "${#src_ip[@]}" -eq 0 ] || [ "${#dst_ip[@]}" -eq 0 ] || [ -z "$direction" ] &&
        die "Interface, destination or source IP/network are mandatory. Use --help for usage information."

    # Validate other mandatory parameters
    [ -z "$latency" ] && [ -z "$jitter" ] && [ -z "$duplicate" ]  && [ -z "$corrupt" ] && [ -z "$reorder" ] && [ -z "$packet_loss" ] &&
        die "At least one of the parameters (latency, jitter, duplicate, corrupt, reorder, packet_loss) must be provided. Use --help for usage information."

    # Check that when using -j, the -l is set
    if [ "$jitter_provided" -eq 1 ] && [ "$latency_provided" -eq 0 ]; then
        die "Jitter can only be used with latency. Use --help for usage information."
    fi

    # Check that direction is only egress, ingress, or both
    if ! [[ "$direction" =~ ^(egress|ingress|both)$ ]]; then
        die "Invalid direction. Valid options are: egress, ingress, or both."
    fi        
}

# Function to validate arguments
validate_arguments() {
    # Validate IPs and numeric values
    for sip in "${src_ip[@]}"; do 
        [ -n "$sip" ] && validate_ip "$sip" "src_ip"
    done
    for dip in "${dst_ip[@]}"; do 
        [ -n "$dip" ] && validate_ip "$dip" "dst_ip"
    done
    [ -n "$latency" ] && latency=$(validate_numeric "$latency" "latency")
    [ -n "$jitter" ] && jitter=$(validate_numeric "$jitter" "jitter")
    [ -n "$packet_loss" ] && packet_loss=$(validate_numeric "$packet_loss" "packet_loss")
    [ -n "$duplicate" ] && duplicate=$(validate_numeric "$duplicate" "duplicate")
    [ -n "$corrupt" ] && corrupt=$(validate_numeric "$corrupt" "corrupt")
    [ -n "$reorder" ] && reorder=$(validate_numeric "$reorder" "reorder")
}

# Function to validate the interface
validate_interface() {
    local interface="$1"
    if ! ip link show "$interface" &>/dev/null; then
        die "Invalid interface: $interface. Please provide a valid network interface."
    fi
}

# Function to validate numeric values
validate_numeric() {
    local val="${1//[^0-9.]}"
    awk -v val="$val" 'BEGIN{if(val<=0) exit 1; print val}' || die "Invalid $2 format. Use a positive numeric value for $2."
}

# Function to process destination Source IP argument
validate_src_ip() {
    local entries="$1"
    IFS=',' read -ra src_entries <<< "$entries"
    for entry in "${src_entries[@]}"; do
        if [[ "$entry" == *":"* ]]; then
            ip=$(echo "$entry" | cut -d':' -f1)
            ports=$(echo "$entry" | cut -d':' -f2 | tr '~' ' ')
            for port in $ports; do
                src_ip+=("$ip:$port")
            done
        else
            src_ip+=("$entry:0")
        fi
    done
}

# Function to process destination Destination IP argument
validate_dst_ip() {
    local entries="$1"
    IFS=',' read -ra dst_entries <<< "$entries"
    for entry in "${dst_entries[@]}"; do
        if [[ "$entry" == *":"* ]]; then
            ip=$(echo "$entry" | cut -d':' -f1)
            ports=$(echo "$entry" | cut -d':' -f2 | tr '~' ' ')
            for port in $ports; do
                dst_ip+=("$ip:$port")
            done
        else
            dst_ip+=("$entry:0")
        fi
    done
}

# Function to validate CIDR IP values
validate_ip() {
    local value="$1"
    local name="$2"
    
    # Split IP and port
    local ip="${value%%:*}"  # everything before the first colon
    local port="${value#*:}" # everything after the first colon

    # Regex to match IP
    local ip_pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}"
    # Regex to optionally match CIDR
    local cidr_pattern="(/([0-2]?[0-9]|3[0-2]))?$"

    # Validate the IP part
    if ! [[ "$ip" =~ ${ip_pattern}${cidr_pattern} ]]; then
        die "Invalid $name format for IP. Please use a valid IPv4 address or CIDR notation IPv4 network for $name and $value"
    fi

    # Validate the port if it exists (if value contains a colon)
    if [[ "$value" == *":"* ]]; then
        if ((port < 0 || port > 65535)); then
            die "Invalid $name format for port. Port $port is not in the range 0-65535."
        fi
    fi
}

# Function to display parameters and results
display_params() {
    local stage="$1"

    echo 
    echo "Network perturbations $stage with the following parameters:" 
    [ -n "$eth_interface" ] && echo "  - Interface: $eth_interface"   
    for sip in "${src_ip[@]}"; do
        [ -n "$sip" ] && echo "  - Source IP/Network: $sip"       
    done
    for dip in "${dst_ip[@]}"; do
        [ -n "$dip" ] && echo "  - Destination IP/Network: $dip"       
    done
    [ -n "$direction" ] && echo "  - Direction: $direction"   
    [ -n "$latency" ] && echo "  - Latency: $latency ms"
    [ -n "$jitter" ] && echo "  - Jitter: $jitter ms"
    [ -n "$packet_loss" ] && echo "  - Packet Loss: $packet_loss %"     
    [ -n "$duplicate" ] && echo "  - Duplication: $duplicate %"    
    [ -n "$corrupt" ] && echo "  - Corruption: $corrupt %"
    [ -n "$reorder" ] && echo "  - Reorder: $reorder %"
    
    if [ "$stage" = "applied" ]; then
        echo
        echo "To rollback, run $0 --rollback --interface $eth_interface"
    fi
    echo 
}

# Function to swap dst_ip and src_ip based on perspectice of rules
swap_ips_if_match() {  
    [ "${#src_ip[@]}" -eq 0 ] || [ "${#dst_ip[@]}" -eq 0 ] && return  # return if either array is empty

    for index in "${!dst_ip[@]}"; do
        extracted_ip="${dst_ip[$index]%%:*}"  # extract IP, considering optional port

        # Compare extracted IP with the local IP
        if [ "$extracted_ip" == "$local_ip" ]; then
            temp="${src_ip[$index]}"
            src_ip[$index]="${dst_ip[$index]}"
            dst_ip[$index]="$temp"
            ips_swapped=1          
        fi
    done
}