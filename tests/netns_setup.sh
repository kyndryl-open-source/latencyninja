#!/usr/bin/env bash
#
# Build (or tear down) an isolated test topology for Latency Ninja.
#
#   root namespace                              namespace "lnpeer"
#   +------------------------+  veth pair  +----------------------------------+
#   | ln0  10.10.0.1         |<----------->| lnpeer0 10.10.0.2, .3, .4         |
#   |                        |             |         10.20.0.1 (routed net)    |
#   | bond0 10.40.0.1        |  2x veth    | lnbr0   10.40.0.2 (bridge)        |
#   |  (active-backup:       |<----------->|  (lnb0p, lnb1p)                   |
#   |   lnb0, lnb1)          |             |                                   |
#   | wg0  10.30.0.1         |  over ln0   | wgp0    10.30.0.2                 |
#   +------------------------+             | TCP listeners: 80 443 8080 9090   |
#                                          +----------------------------------+
#
# Uses nsenter rather than "ip -n"/"ip netns exec", which remount /sys and are denied by SELinux
# when run from a systemd service (reboot test on Fedora).
#
# Usage: sudo tests/netns_setup.sh up|down|wg-recreate|bond-recreate

set -euo pipefail

ns="lnpeer"
dev="ln0"
peer_dev="lnpeer0"
helpers_dir="$(cd "$(dirname "$0")" && pwd)/helpers"
pid_file="/run/latencyninja-test-listener.pid"
key_dir="/etc/wireguard/latencyninja-test"   # wg AppArmor profile (Ubuntu) only reads keys here

wg_down() { ip link delete wg0 2>/dev/null || true; }

# Create wg0 in the root namespace (the peer side lives in lnpeer and is created once)
wg_up() {
    ip link add wg0 type wireguard
    wg set wg0 listen-port 51820 private-key "$key_dir/a.key" \
        peer "$(cat "$key_dir/b.pub")" endpoint 10.10.0.2:51821 allowed-ips 10.30.0.2/32
    ip addr add 10.30.0.1/24 dev wg0
    ip link set wg0 up
}

bond_down() { for d in bond0 lnb0 lnb1; do ip link delete "$d" 2>/dev/null || true; done; }

bond_up() {
    ip link add bond0 type bond mode active-backup miimon 100
    for i in 0 1; do
        ip link add "lnb$i" type veth peer name "lnb${i}p"
    done
    # udev assigns new veths a MAC address asynchronously (MACAddressPolicy). If that happens after
    # enslaving, the slave's MAC no longer matches the bond's and its traffic is dropped, so wait.
    udevadm settle
    for i in 0 1; do
        ip link set "lnb${i}p" netns "$ns"
        nsenter --net="/run/netns/$ns" ip link set "lnb${i}p" master lnbr0
        nsenter --net="/run/netns/$ns" ip link set "lnb${i}p" up
        ip link set "lnb$i" master bond0
    done
    ip addr add 10.40.0.1/24 dev bond0
    ip link set bond0 up
}

down() {
    [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"
    wg_down
    bond_down
    ip link delete "$dev" 2>/dev/null || true
    ip netns delete "$ns" 2>/dev/null || true
    for d in /sys/class/net/ln[ie]-*; do
        [ -e "$d" ] && ip link delete "$(basename "$d")" 2>/dev/null || true
    done
    rm -rf "$key_dir"
}

up() {
    down
    ip netns add "$ns"
    nsenter --net="/run/netns/$ns" ip link set lo up

    # Plain veth pair
    ip link add "$dev" type veth peer name "$peer_dev"
    ip link set "$peer_dev" netns "$ns"
    ip addr add 10.10.0.1/24 dev "$dev"
    ip link set "$dev" up
    for a in 10.10.0.2 10.10.0.3 10.10.0.4 10.20.0.1; do
        nsenter --net="/run/netns/$ns" ip addr add "$a/24" dev "$peer_dev"
    done
    nsenter --net="/run/netns/$ns" ip link set "$peer_dev" up
    ip route replace 10.20.0.0/24 via 10.10.0.2 dev "$dev"

    # Bond (root ns) <-> bridge (peer ns)
    nsenter --net="/run/netns/$ns" ip link add lnbr0 type bridge
    nsenter --net="/run/netns/$ns" ip addr add 10.40.0.2/24 dev lnbr0
    nsenter --net="/run/netns/$ns" ip link set lnbr0 up
    bond_up

    # WireGuard tunnel over ln0
    mkdir -p "$key_dir"; chmod 700 "$key_dir"; umask 077
    wg genkey | tee "$key_dir/a.key" | wg pubkey > "$key_dir/a.pub"
    wg genkey | tee "$key_dir/b.key" | wg pubkey > "$key_dir/b.pub"
    nsenter --net="/run/netns/$ns" ip link add wgp0 type wireguard
    nsenter --net="/run/netns/$ns" wg set wgp0 listen-port 51821 private-key "$key_dir/b.key" \
        peer "$(cat "$key_dir/a.pub")" endpoint 10.10.0.1:51820 allowed-ips 10.30.0.1/32
    nsenter --net="/run/netns/$ns" ip addr add 10.30.0.2/24 dev wgp0
    nsenter --net="/run/netns/$ns" ip link set wgp0 up
    wg_up

    setsid nsenter --net="/run/netns/$ns" python3 "$helpers_dir/listener.py" 80 443 8080 9090 5001 5002 </dev/null >/dev/null 2>&1 &
    echo $! > "$pid_file"
    sleep 1
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    wg-recreate) wg_down; wg_up ;;
    bond-recreate) bond_down; bond_up ;;
    *) echo "Usage: $0 up|down|wg-recreate|bond-recreate"; exit 1 ;;
esac
