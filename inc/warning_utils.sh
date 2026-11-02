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

# Warnings about rules that are accepted but may not do what was expected. They are shown before anything is
# applied (and by --dry-run), and never stop the rules from being applied.

# Function to warn that IPv6 traffic is not affected: the rules only match IPv4, so an application that reaches
# the target over IPv6 (dual-stack hosts often prefer it) is not slowed down
warn_ipv6_unaffected() {
    local addresses
    addresses=$($ip_path -6 -o address show dev "$eth_interface" scope global 2>/dev/null | awk '{print $4}' | paste -sd, -)
    [ -n "$addresses" ] || return 0
    echo "Warning: $eth_interface has IPv6 addresses ($addresses). These rules only affect IPv4 traffic: traffic to the same targets over IPv6 is not affected, because IPv6 is not supported yet." >&2
}

# Function to warn when the rules also cover the default gateway: traffic to and from the gateway, which is
# the way out of the subnet, is then slowed down too
warn_gateway_covered() {
    local gateway entry address covered=""
    local -A seen=()

    while read -r gateway; do
        [ -n "$gateway" ] || continue
        for entry in "${src_ip[@]}" "${dst_ip[@]}"; do
            # An entry with a port only matches that port, not the traffic to the gateway as a whole
            [ "${entry##*:}" = "0" ] || continue
            address="${entry%:*}"
            if ip_in_network "$gateway" "$address" && [ -z "${seen[$gateway]+set}" ]; then
                seen[$gateway]=1
                covered="${covered:+$covered, }$gateway"
            fi
        done
    done < <($ip_path -4 route show default dev "$eth_interface" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1)}')
    [ -n "$covered" ] || return 0
    echo "Warning: these rules also cover the default gateway of $eth_interface ($covered), so all traffic through it is affected, not only traffic to your targets. Use a more specific --dst_ip or add a port to limit it." >&2
}
