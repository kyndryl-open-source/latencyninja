

    # Compute the half-latency if latency is applied
    if [ "$direction" == "both" ]; then
        # Compute the half-latency if latency is applied
        if [ ! -z "$latency" ]; then
            half_latency=$(($latency / 2))
        else
            half_latency=$latency
        fi
    fi



# Function for configuring ingress traffic controls
configure_ingress_traffic_controls() {
    local selected_interface="$1"
    local ifb0_interface="$2"
    local destination_ip="$3"
    local latency="$4"
    local jitter="$5"
    local packet_loss="$6"
    local duplicate="$7"
    local corrupt="$8"
    local reorder="$9"
    
    # Redirect ingress traffic to ifb0
    delete_qdisc_if_exists "$selected_interface" "ingress" "ffff: ingress"
    tc qdisc add dev "$selected_interface" handle ffff: ingress || die "Failed to set up ingress qdisc."
    tc filter add dev "$selected_interface" parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb0_interface" || die "Failed to redirect incoming traffic to $ifb0_interface."
    rollback_required=1

    # Validate latency, jitter, packet_loss, duplicate, corrupt, and reorder
    [ -n "$latency" ] && validate_numeric_format "$latency" "latency"
    [ -n "$jitter" ] && validate_numeric_format "$jitter" "jitter"
    [ -n "$packet_loss" ] && validate_numeric_format "$packet_loss" "packet_loss"
    [ -n "$duplicate" ] && validate_numeric_format "$duplicate" "duplicate"
    [ -n "$corrupt" ] && validate_numeric_format "$corrupt" "corrupt"
    [ -n "$reorder" ] && validate_numeric_format "$reorder" "reorder"

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
}

# Function for configuring egress traffic controls
configure_egress_traffic_controls() {
    local selected_interface="$1"
    local ifb1_interface="$2"
    local source_ip="$3"
    local destination_ip="$4"
    local latency="$5"
    local jitter="$6"
    local packet_loss="$7"
    local duplicate="$8"
    local corrupt="$9"
    local reorder="${10}"

    # Redirect egress traffic to ifb1
    delete_qdisc_if_exists "$selected_interface" "root" "1: prio"
    tc qdisc add dev "$selected_interface" root handle 1: prio || die "Failed to add egress qdisc."
    tc filter add dev "$selected_interface" parent 1: protocol ip u32 match u32 0 0 action mirred egress redirect dev "$ifb1_interface" || die "Failed to redirect outgoing traffic to $ifb1_interface."

    # Validate latency, jitter, packet_loss, duplicate, corrupt, and reorder
    [ -n "$latency" ] && validate_numeric_format "$latency" "latency"
    [ -n "$jitter" ] && validate_numeric_format "$jitter" "jitter"
    [ -n "$packet_loss" ] && validate_numeric_format "$packet_loss" "packet_loss"
    [ -n "$duplicate" ] && validate_numeric_format "$duplicate" "duplicate"
    [ -n "$corrupt" ] && validate_numeric_format "$corrupt" "corrupt"
    [ -n "$reorder" ] && validate_numeric_format "$reorder" "reorder"

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


    # Apply delay to egress (outgoing) traffic on ifb1 for specific IP addresses
    delete_qdisc_if_exists "$ifb1_interface" "root" "1: prio"
    tc qdisc add dev "$ifb1_interface" root handle 1: prio || die "Failed to add egress qdisc on $ifb1_interface."
    tc filter add dev "$ifb1_interface" parent 1: protocol ip prio 1 u32 match ip src "$source_ip" match ip dst "$destination_ip" flowid 1:1 || die "Failed to add egress filter on $ifb1_interface."
    tc qdisc add dev "$ifb1_interface" parent 1:1 handle 2: netem $netem_params || die "Failed to add egress delay and other parameters."

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