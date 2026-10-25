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

# SSH lockout guard: rules that match the traffic of an SSH session to this machine (loss, a low rate or
# a long delay on the interface carrying it) can make the session unusable, and with it the only way to
# roll the rules back. Before applying rules, the established SSH sessions that reach the machine through
# the target interface are compared with the rules. If one would be affected, the rules are refused
# unless they roll back by themselves (--duration) or the guard is bypassed (--allow-ssh).
#
# Sessions come from ss (connections of sshd and dropbear) and, on the host, from SSH_CONNECTION, which
# is set in the shell of the session running this command. The check is deliberately conservative: a
# rule counts as matching when it covers the client address with port 0 (any), the client's port or the
# SSH server port, on either the source or the destination side.

# Function to print the IPv4 address of an ss address ("1.2.3.4:22", "[::ffff:1.2.3.4]:22")
ssh_addr_ip() {
    local address="${1%:*}"
    address="${address#[}"
    address="${address%]}"
    echo "${address#::ffff:}"
}

# Function to print the established SSH sessions as "<client ip> <client port> <local ip> <local port>" lines
ssh_sessions() {
    local ss_cmd local_address peer_address client_ip local_ip client_port local_port
    ss_cmd=$(command -v ss)
    if [ -n "$ss_cmd" ]; then
        # The last three columns are always local address, peer address and process
        while read -r local_address peer_address; do
            client_ip=$(ssh_addr_ip "$peer_address")
            local_ip=$(ssh_addr_ip "$local_address")
            [[ "$client_ip" =~ ^[0-9.]+$ ]] && [[ "$local_ip" =~ ^[0-9.]+$ ]] || continue
            echo "$client_ip ${peer_address##*:} $local_ip ${local_address##*:}"
        done < <($ss_cmd -Htnp state established 2>/dev/null | awk '/"(sshd|dropbear)/ {print $(NF-2), $(NF-1)}')
    fi
    # Inside a namespace SSH_CONNECTION describes a session of the host
    if ! in_namespace && [ -n "$SSH_CONNECTION" ]; then
        read -r client_ip client_port local_ip local_port <<< "$SSH_CONNECTION"
        [[ "$client_ip" =~ ^[0-9.]+$ ]] && echo "$client_ip $client_port $local_ip $local_port"
    fi
}

# Function to convert an IPv4 address to an integer
ip_to_int() {
    local octets=()
    IFS=. read -ra octets <<< "$1"
    echo $(( (10#${octets[0]} << 24) | (10#${octets[1]} << 16) | (10#${octets[2]} << 8) | 10#${octets[3]} ))
}

# Function to check if an IPv4 address is inside a network ("1.2.3.0/24", or a single address)
ip_in_network() {
    local address="$1" network="$2" length=32 mask
    if [[ "$network" == */* ]]; then
        length="${network#*/}"
        network="${network%/*}"
    fi
    mask=$(( (0xFFFFFFFF << (32 - length)) & 0xFFFFFFFF ))
    [ $(( $(ip_to_int "$address") & mask )) -eq $(( $(ip_to_int "$network") & mask )) ]
}

# Function to check if the src_ip/dst_ip rules cover an SSH session: the client is in one of the lists
# and the local address in the other, with a port that is 0, the client's or the server's.
rules_match_ssh_session() {
    local client_ip="$1" client_port="$2" local_ip="$3" local_port="$4"
    local sip dip s_net s_port d_net d_port

    for sip in "${src_ip[@]}"; do
        for dip in "${dst_ip[@]}"; do
            s_net="${sip%:*}" s_port="${sip##*:}"
            d_net="${dip%:*}" d_port="${dip##*:}"
            # Client as destination (the usual orientation), or as source when the rules are written from the other end
            if ip_in_network "$client_ip" "$d_net" && ip_in_network "$local_ip" "$s_net" && \
               { [ "$d_port" = "0" ] || [ "$d_port" = "$client_port" ] || [ "$d_port" = "$local_port" ]; }; then
                return 0
            fi
            if ip_in_network "$client_ip" "$s_net" && ip_in_network "$local_ip" "$d_net" && \
               { [ "$s_port" = "0" ] || [ "$s_port" = "$client_port" ] || [ "$s_port" = "$local_port" ]; }; then
                return 0
            fi
        done
    done
    return 1
}

# Function to refuse rules that would affect an SSH session reaching this machine through the target interface
check_ssh_lockout() {
    [ "$allow_ssh" -eq 1 ] && return 0

    local client_ip client_port local_ip local_port route_dev affected="" seen=" "
    while read -r client_ip client_port local_ip local_port; do
        [ -n "$client_ip" ] || continue
        [[ "$seen" == *" $client_ip:$client_port "* ]] && continue
        seen+="$client_ip:$client_port "
        # Only sessions whose traffic goes through the target interface
        route_dev=$($ip_path -o route get "$client_ip" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
        [ "$route_dev" = "$eth_interface" ] || continue
        rules_match_ssh_session "$client_ip" "$client_port" "$local_ip" "$local_port" && affected+="${affected:+, }$client_ip"
    done < <(ssh_sessions)
    [ -n "$affected" ] || return 0

    if [ -n "$duration" ]; then
        echo "Warning: these rules affect your SSH session from $affected on $eth_interface. They roll back automatically after $duration." >&2
        return 0
    fi
    die "These rules would also affect your SSH session from $affected on $eth_interface and could lock you out. Exclude that address from --src_ip/--dst_ip, add --duration <time> so the rules roll back automatically, or add --allow-ssh to apply them anyway."
}
