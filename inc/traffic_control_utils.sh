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

# Function for configuring ingress traffic controls
configure_ingress_traffic_controls() {
    local interface="$1"
    local ifb0_interface="$2"
    local src_ip=("${!3}")  # Convert src_ip to an array
    local dst_ip=("${!4}")  # Receive dst_ip as an array
    local latency="$5"
    local jitter="$6"
    local packet_loss="$7"
    local duplicate="$8"
    local corrupt="$9"
    local reorder="${10}"

    swap_ips_if_match # Allows to switch perspective of traffic direction

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
    delete_qdisc_if_exists "$eth_interface" "ingress" "ffff:"
    $tc_path qdisc add dev "$eth_interface" handle ffff: ingress || die "Failed to set up ingress qdisc for $eth_interface."
    $tc_path filter add dev "$eth_interface" protocol ip parent ffff: u32 match u32 0 0 action mirred egress redirect dev "$ifb0_interface" || die "Failed to redirect incoming traffic to $ifb0_interface."

    # Modify the netem command based on the new options
    local netem_params=""
    [ -n "$latency" ] && netem_params="delay ${latency}ms"
    [ -n "$jitter" ] && netem_params="$netem_params ${jitter}ms"
    [ -n "$packet_loss" ] && netem_params="$netem_params loss $packet_loss%"
    [ -n "$duplicate" ] && netem_params="$netem_params duplicate $duplicate%"
    [ -n "$corrupt" ] && netem_params="$netem_params corrupt $corrupt%"
    [ -n "$reorder" ] && netem_params="$netem_params reorder $reorder%"
    
    # Apply delay to ingress (incoming) traffic on ifb0 for specific IP addresses
    delete_qdisc_if_exists "$ifb0_interface" "root" "prio 1:0"
    $tc_path qdisc add dev "$ifb0_interface" root handle 1:0 prio || die "Failed to add ingress qdisc for $eth_interface."
    for sip in "${src_ip[@]}"; do
        for dip in "${dst_ip[@]}"; do
            if [ -n "$sip" ] && [ -n "$dip" ]; then      
                stripped_sip="${sip%%:*}"  # Extract IP part before the colon
                if [ "$ips_swapped" -eq 1 ]; then
                    stripped_dprt="${sip##*:}"
                else
                    stripped_dprt="${dip##*:}"
                fi
                stripped_dip="${dip%%:*}"  # Extract IP part before the colon        
                if [ "$stripped_dprt" != "0" ]; then
                    if [ "$ips_swapped" -eq 1 ]; then
                        $tc_path filter add dev "$ifb0_interface" protocol ip parent 1:0 prio 1 u32 match ip src "$stripped_dip" match ip dst "$stripped_sip" match ip dport "$stripped_dprt" 0xffff flowid 1:1 || die "Failed to add ingress filter on $ifb0_interface for $stripped_dip to $stripped_sip on port $stripped_dprt."
                    else
                        $tc_path filter add dev "$ifb0_interface" protocol ip parent 1:0 prio 1 u32 match ip src "$stripped_dip" match ip sport "$stripped_dprt" 0xffff match ip dst "$stripped_sip" flowid 1:1 || die "Failed to add ingress filter on $ifb0_interface for $stripped_dip to $stripped_sip on port $stripped_dprt."
                    fi
                else
                    $tc_path filter add dev "$ifb0_interface" protocol ip parent 1:0 prio 1 u32 match ip src "$stripped_dip" match ip dst "$stripped_sip" flowid 1:1 || die "Failed to add ingress filter on $ifb0_interface for $sip to $dip."
                fi
            fi
        done
    done
    
    $tc_path qdisc add dev "$ifb0_interface" parent 1:1 handle 10:0 netem $netem_params || die "Failed to add ingress network perturbations."    
}

# Function for configuring egress traffic controls
configure_egress_traffic_controls() {
    local interface="$1"
    local ifb1_interface="$2"
    local src_ip=("${!3}")  # Receive src_ip as an array
    local dst_ip=("${!4}")  # Receive dst_ip as an array
    local latency="$5"
    local jitter="$6"
    local packet_loss="$7"
    local duplicate="$8"
    local corrupt="$9"
    local reorder="${10}"

    swap_ips_if_match # Allows to switch perspective of traffic direction

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
    delete_qdisc_if_exists "$eth_interface" "root" "prio 1:0"
    $tc_path qdisc add dev "$eth_interface" root handle 1:0 prio || die "Failed to add egress qdisc for $eth_interface."
    $tc_path filter add dev "$eth_interface" protocol ip parent 1:0 u32 match u32 0 0 action mirred egress redirect dev "$ifb1_interface" || die "Failed to redirect outgoing traffic to $ifb1_interface."

    # Modify the netem command based on the new options    
    local netem_params=""
    [ -n "$latency" ] && netem_params="delay ${latency}ms"
    [ -n "$jitter" ] && netem_params="$netem_params ${jitter}ms"
    [ -n "$packet_loss" ] && netem_params="$netem_params loss $packet_loss%"
    [ -n "$duplicate" ] && netem_params="$netem_params duplicate $duplicate%"
    [ -n "$corrupt" ] && netem_params="$netem_params corrupt $corrupt%"
    [ -n "$reorder" ] && netem_params="$netem_params reorder $reorder%"

    # Apply delay to egress (outgoing) traffic on ifb1 for specific IP addresses
    delete_qdisc_if_exists "$ifb1_interface" "root" "prio 1:0"
    $tc_path qdisc add dev "$ifb1_interface" root handle 1:0 prio || die "Failed to add egress qdisc on $ifb1_interface." 
    for sip in "${src_ip[@]}"; do
        for dip in "${dst_ip[@]}"; do
            if [ -n "$sip" ] && [ -n "$dip" ]; then            
                stripped_sip="${sip%%:*}"  # Extract IP part before the colon
                if [ "$ips_swapped" -eq 1 ]; then
                    stripped_dprt="${sip##*:}"
                else
                    stripped_dprt="${dip##*:}"
                fi
                stripped_dip="${dip%%:*}"  # Extract IP part before the colon        
                if [ "$stripped_dprt" != "0" ]; then
                    if [ "$ips_swapped" -eq 1 ]; then
                        echo $stripped_dprt
                        debug_command $tc_path filter add dev $ifb1_interface protocol ip parent 1:0 prio 1 u32 match ip src $stripped_sip match ip sport $stripped_dprt 0xffff match ip dst $stripped_dip flowid 1:1 || die "Failed to add ingress filter on $ifb1_interface for $stripped_dip to $stripped_sip on port $stripped_dprt."
                    else
                        $tc_path filter add dev $ifb1_interface protocol ip parent 1:0 prio 1 u32 match ip src $stripped_sip match ip dst $stripped_dip match ip dport $stripped_dprt 0xffff flowid 1:1 || die "Failed to add ingress filter on $ifb1_interface for $stripped_dip to $stripped_sip on port $stripped_dprt."
                    fi
                else
                    $tc_path filter add dev $ifb1_interface protocol ip parent 1:0 prio 1 u32 match ip src $stripped_sip match ip dst $stripped_dip flowid 1:1 || die "Failed to add ingress filter on $ifb1_interface for $sip to $dip."
                fi
            fi
        done
    done
    $tc_path qdisc add dev $ifb1_interface parent 1:1 handle 20:0 netem $netem_params || die "Failed to add egress network perturbations."
}
