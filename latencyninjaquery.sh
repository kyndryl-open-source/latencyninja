#!/bin/bash

get_cidr_from_mask() {
    local mask_decimal="$1"
    local count=0
    local IFS=.
    for byte in $mask_decimal; do
        while [ $byte -gt 0 ]; do
            count=$((count+byte%2))
            byte=$((byte/2))
        done
    done
    echo $count
}

convert_hex_to_ip() {
    local ip_hex="$1"
    printf "%d.%d.%d.%d" $(echo $ip_hex | sed 's/../0x& /g')
}

extract_netem_details() {
    local dev="$1"
    tc -s qdisc show dev "$dev" | grep -E "delay|loss|duplicate|reorder|corrupt" | sed 's/^.*delay/netem: delay/' | sed 's/  / jitter /' | sed 's/gap [0-9]*//'
}


# Extract all network devices
devices=$(ls /sys/class/net/)

# Iterate over each device
for dev in $devices; do
    echo "Device: $dev"
    
    src_ip=""
    src_port=""    
    src_mask=""
    dst_ip=""
    dst_mask=""
    dst_port=""

    # Extract details from tc filter show dev command
    while read -r line; do

        # Extract IP addresses and their masks
        if [[ $line =~ "match" ]] && [[ $line =~ "at 12" ]]; then
            src_ip=$(convert_hex_to_ip "$(echo $line | awk '{print $2}' | cut -d'/' -f1)")
            src_mask=$(convert_hex_to_ip "$(echo $line | awk '{print $2}' | cut -d'/' -f2)")
            src_cidr=$(get_cidr_from_mask "$src_mask")
            src_ip="${src_ip}/${src_cidr}"
        elif [[ $line =~ "match" ]] && [[ $line =~ "at 16" ]]; then
            dst_ip=$(convert_hex_to_ip "$(echo $line | awk '{print $2}' | cut -d'/' -f1)")
            dst_mask=$(convert_hex_to_ip "$(echo $line | awk '{print $2}' | cut -d'/' -f2)")
            dst_cidr=$(get_cidr_from_mask "$dst_mask")
            dst_ip="${dst_ip}/${dst_cidr}"
        fi
        
        # Extract source and destination ports
        if [[ $line =~ "match" ]] && [[ $line =~ "at 20" ]]; then
            full_port_hex=$(echo $line | awk '{print $2}' | cut -d'/' -f1)
            
            src_port_hex="${full_port_hex:0:4}"
            dst_port_hex="${full_port_hex:4:4}"
            
            src_port=$((16#$src_port_hex))
            dst_port=$((16#$dst_port_hex))
        fi

        # If line starts with 'filter', it's a new entry. Print previous values and reset.
        if [[ $line =~ ^filter ]]; then
            if [[ -n $src_ip || -n $dst_ip || -n $src_port || -n $dst_port ]]; then
                output=""
                [ -n "$src_ip" ] && output="src_ip: $src_ip"
                [ -n "$src_port" ] && output="${output:+$output, }src_port: $src_port"
                [ -n "$dst_ip" ] && output="${output:+$output, }dst_ip: $dst_ip"
                [ -n "$dst_port" ] && output="${output:+$output, }dst_port: $dst_port"
                [ -n "$output" ] && echo "$output"

                src_ip=""
                src_mask=""
                dst_ip=""
                dst_mask=""
                src_port=""
                dst_port=""
            fi
        fi


    done < <(tc filter show dev $dev)

    # Print any remaining values
    output=""
    if [[ -n $src_ip ]]; then
        output+="src_ip: $src_ip"
    fi

    if [[ -n $src_port ]]; then
        [ -n "$output" ] && output+=", "  # Add a comma separator if there's already some output
        output+="src_port: $src_port"
    fi

    if [[ -n $dst_ip ]]; then
        [ -n "$output" ] && output+=", "  # Add a comma separator if there's already some output
        output+="dst_ip: $dst_ip"
    fi

    if [[ -n $dst_port ]]; then
        [ -n "$output" ] && output+=", "  # Add a comma separator if there's already some output
        output+="dst_port: $dst_port"
    fi

    if [[ -n $output ]]; then
        echo "$output"
    fi

    # Extract netem details
    echo "$(extract_netem_details "$dev")"
    echo ""
done
