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

# Function to get CIDR notation from the subnet mask
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

# Function to convert HEX to IP as HEX is used by tc.
convert_hex_to_ip() {
    local ip_hex="$1"
    printf "%d.%d.%d.%d" $(echo $ip_hex | sed 's/../0x& /g')
}

# Function to extract current tc netem rules
extract_netem_details() {
    local dev="$1"
    $tc_path qdisc show dev "$dev" | grep '^qdisc netem' | sed -E 's/^qdisc netem [^ ]+ (root|parent [^ ]+) (refcnt [0-9]+ )?limit [0-9]+ ?/netem: /' | sed 's/  / jitter /' | sed 's/gap [0-9]*//'
}

# Function to print one filter of a device, or collect it as JSON in query_filters. Empty values are left out.
query_emit_filter() {
    local f_src_ip="$1" f_src_port="$2" f_dst_ip="$3" f_dst_port="$4" output=""

    [ -z "$f_src_ip$f_src_port$f_dst_ip$f_dst_port" ] && return
    if [ "$output_format" = "json" ]; then
        query_filters+=("$($jq_path -nc --arg sip "$f_src_ip" --arg sp "$f_src_port" --arg dip "$f_dst_ip" --arg dp "$f_dst_port" \
            '{src_ip: $sip, src_port: $sp, dst_ip: $dip, dst_port: $dp} | with_entries(select(.value != ""))
             | if .src_port then .src_port |= tonumber else . end | if .dst_port then .dst_port |= tonumber else . end')")
        return
    fi
    [ -n "$f_src_ip" ] && output="src_ip: $f_src_ip"
    [ -n "$f_src_port" ] && output="${output:+$output, }src_port: $f_src_port"
    [ -n "$f_dst_ip" ] && output="${output:+$output, }dst_ip: $f_dst_ip"
    [ -n "$f_dst_port" ] && output="${output:+$output, }dst_port: $f_dst_port"
    [ -n "$output" ] && echo "$output"
}

# Function to turn a netem line from extract_netem_details into a JSON object: the raw text and the values in it
netem_line_json() {
    local line="$1" delay="" jitter="" loss="" duplicate="" corrupt="" reorder="" rate=""
    [[ "$line" =~ delay\ ([0-9.]+[mu]?s) ]] && delay="${BASH_REMATCH[1]}"
    [[ "$line" =~ jitter\ ([0-9.]+[mu]?s) ]] && jitter="${BASH_REMATCH[1]}"
    [[ "$line" =~ loss\ ([0-9.]+%) ]] && loss="${BASH_REMATCH[1]}"
    [[ "$line" =~ duplicate\ ([0-9.]+%) ]] && duplicate="${BASH_REMATCH[1]}"
    [[ "$line" =~ corrupt\ ([0-9.]+%) ]] && corrupt="${BASH_REMATCH[1]}"
    [[ "$line" =~ reorder\ ([0-9.]+%) ]] && reorder="${BASH_REMATCH[1]}"
    [[ "$line" =~ rate\ ([0-9.]+[A-Za-z]+) ]] && rate="${BASH_REMATCH[1]}"
    $jq_path -nc --arg raw "$line" --arg delay "$delay" --arg jitter "$jitter" --arg loss "$loss" --arg duplicate "$duplicate" \
        --arg corrupt "$corrupt" --arg reorder "$reorder" --arg rate "$rate" \
        '{raw: $raw, delay: $delay, jitter: $jitter, loss: $loss, duplicate: $duplicate, corrupt: $corrupt, reorder: $reorder, rate: $rate}
         | with_entries(select(.value != ""))'
}

# Function to list the pending timed rollbacks as JSON objects (interface, seconds left, awaiting confirmation)
scheduled_rollbacks_json() {
    local file interface left
    for file in "$state_dir"/*.expires; do
        [ -f "$file" ] || continue
        interface=$(basename "$file" .expires)
        left=$(( $(cat "$file") - $(date +%s) ))
        [ "$left" -lt 0 ] || ! systemctl is-active -q "$(rollback_unit_name "$interface").timer" 2>/dev/null && continue
        $jq_path -nc --arg interface "$interface" --argjson left "$left" --argjson unconfirmed "$([ -f "${file%.expires}.confirm" ] && echo 1 || echo 0)" \
            '{interface: $interface, seconds_left: $left, awaiting_confirmation: ($unconfirmed == 1)}'
    done
}

# Function to query current tc rules (--format json prints them as JSON)
query(){
    local json=0 devices_json=()
    [ "$output_format" = "json" ] && json=1
    query_filters=()
    in_namespace && [ "$json" -eq 0 ] && echo -e "Namespace: $LATENCYNINJA_NETNS_DESC\n"

    # Extract all network devices
    devices=$(list_network_devices)

    # Iterate over each device
    for dev in $devices; do
        [ "$json" -eq 0 ] && echo "Device: $dev"
        query_filters=()

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
                    query_emit_filter "$src_ip" "$src_port" "$dst_ip" "$dst_port"

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
        query_emit_filter "$src_ip" "$src_port" "$dst_ip" "$dst_port"

        # Extract netem details
        if [ "$json" -eq 1 ]; then
            local netem_json=() netem_line
            while IFS= read -r netem_line; do
                [ -n "$netem_line" ] && netem_json+=("$(netem_line_json "$netem_line")")
            done < <(extract_netem_details "$dev")
            devices_json+=("$($jq_path -nc --arg device "$dev" --argjson filters "$(printf '%s\n' "${query_filters[@]}" | $jq_path -s .)" \
                --argjson netem "$(printf '%s\n' "${netem_json[@]}" | $jq_path -s .)" '{device: $device, filters: $filters, netem: $netem}')")
        else
            echo "$(extract_netem_details "$dev")"
            echo ""
        fi
    done

    local persisted
    if [ "$json" -eq 1 ]; then
        $jq_path -n --arg ns "${LATENCYNINJA_NETNS_DESC:-}" \
            --argjson devices "$(printf '%s\n' "${devices_json[@]}" | $jq_path -s .)" \
            --argjson persisted "$(persisted_interfaces | $jq_path -R . | $jq_path -s 'map(select(. != ""))')" \
            --argjson rollbacks "$(scheduled_rollbacks_json | $jq_path -s .)" \
            '{namespace: (if $ns == "" then null else $ns end), devices: $devices, persisted_interfaces: $persisted, scheduled_rollbacks: $rollbacks}'
        return
    fi
    persisted=$(persisted_interfaces | tr '\n' ' ')
    echo "Persisted interfaces: ${persisted:-none}"
    echo "Scheduled rollbacks: $(scheduled_rollbacks)"
}

# Function to show the traffic counters of the netem qdiscs of the interfaces with rules (--stats). It covers every
# interface with rules, or only --interface. Packets that netem dropped (packet loss, or a full queue) are counted
# as drops; --format json prints the counters as JSON.
show_stats() {
    local interfaces=() interface direction ifb_name found=0 rows=() stats packets bytes drops overlimits requeues backlog

    if [ -n "$eth_interface" ]; then
        $ip_path link show "$eth_interface" &>/dev/null || die "Invalid interface: $eth_interface. Please provide a valid network interface."
        interfaces=("$eth_interface")
    else
        mapfile -t interfaces < <(active_interfaces)
    fi

    [ "$output_format" = "text" ] && { echo; in_namespace && echo -e "Namespace: $LATENCYNINJA_NETNS_DESC\n"; printf '%-12s %-8s %-10s %12s %14s %10s %11s %9s\n' INTERFACE DIRECTION QDISC PACKETS BYTES DROPPED OVERLIMITS REQUEUES; }
    for interface in "${interfaces[@]}"; do
        for direction in ingress egress; do
            [ "$direction" = "ingress" ] && ifb_name=$(ifb_name_for "lni-" "$interface") || ifb_name=$(ifb_name_for "lne-" "$interface")
            $ip_path link show "$ifb_name" &>/dev/null || continue
            stats=$($tc_path -j -s qdisc show dev "$ifb_name" 2>/dev/null | $jq_path -r '[.[] | select(.kind == "netem")] | first // empty | [.packets, .bytes, .drops, .overlimits, .requeues, .backlog] | map(. // 0) | @tsv')
            [ -n "$stats" ] || continue
            found=1
            read -r packets bytes drops overlimits requeues backlog <<< "$stats"
            if [ "$output_format" = "json" ]; then
                rows+=("$($jq_path -nc --arg interface "$interface" --arg direction "$direction" --argjson packets "$packets" --argjson bytes "$bytes" \
                    --argjson drops "$drops" --argjson overlimits "$overlimits" --argjson requeues "$requeues" --argjson backlog "$backlog" \
                    '{interface: $interface, direction: $direction, qdisc: "netem", packets: $packets, bytes: $bytes, drops: $drops,
                      overlimits: $overlimits, requeues: $requeues, backlog_bytes: $backlog}')")
            else
                printf '%-12s %-8s %-10s %12s %14s %10s %11s %9s\n' "$interface" "$direction" netem "$packets" "$bytes" "$drops" "$overlimits" "$requeues"
            fi
        done
    done

    if [ "$output_format" = "json" ]; then
        printf '%s\n' "${rows[@]}" | $jq_path -s --arg ns "${LATENCYNINJA_NETNS_DESC:-}" '{namespace: (if $ns == "" then null else $ns end), stats: .}'
    else
        [ "$found" -eq 0 ] && echo "No Latency Ninja rules${eth_interface:+ on $eth_interface}. Apply some first, or see --show-interfaces."
        echo
    fi
}
