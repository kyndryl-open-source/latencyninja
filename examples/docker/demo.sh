#!/usr/bin/env bash
#
# Walk through container targeting with Latency Ninja. Run on a Linux host with Docker, as root:
#
#   sudo examples/docker/demo.sh [up|run|down]      (default: up, then run)
#
# Example for human testers; not run by CI. It changes only the ln-client container's network, and
# rolls the rules back at the end (or when interrupted).

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ln="$here/../../latencyninja"
server_ip=10.99.1.20
compose=(docker compose -f "$here/compose.yaml")

[ "$(uname -s)" = Linux ] || { echo "Latency Ninja needs a Linux host (Docker Desktop's VM is not the host)."; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0"; exit 1; }
command -v docker >/dev/null || { echo "docker not found"; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
in_client() { docker exec ln-client "$@"; }
rtt() { in_client ping -c 8 -i 0.2 -q "$server_ip" | awk -F/ '/^rtt|^round-trip/ {print "avg RTT " $5 " ms"}'; }
fetch_time() { in_client curl -s -o /dev/null -w "port $1: %{time_total}s\n" "http://$server_ip:$1/"; }
cleanup() { "$ln" --container ln-client --interface eth0 --rollback >/dev/null 2>&1 || true; }

up() { "${compose[@]}" up -d --build; sleep 2; }

run() {
    trap cleanup EXIT

    step "Containers on the host, as Latency Ninja sees them"
    "$ln" --container ln-client --show-interfaces

    step "Baseline"
    rtt

    step "Latency, jitter and loss towards the server (--latency 100 --jitter 10 --packet_loss 1)"
    "$ln" --container ln-client --interface eth0 --dst_ip "$server_ip" --latency 100 --jitter 10 --packet_loss 1
    rtt
    "$ln" --container ln-client --query
    "$ln" --container ln-client --interface eth0 --rollback

    step "One port only: delay 8080, leave 9090 alone"
    "$ln" --container ln-client --interface eth0 --dst_ip "$server_ip:8080" --latency 200
    fetch_time 8080
    fetch_time 9090
    "$ln" --container ln-client --interface eth0 --rollback

    step "A profile (--profile 4g), then a bandwidth limit with iperf3"
    "$ln" --container ln-client --interface eth0 --dst_ip "$server_ip" --profile 4g
    rtt
    "$ln" --container ln-client --interface eth0 --rollback
    "$ln" --container ln-client --interface eth0 --dst_ip "$server_ip" --rate 5mbit
    in_client iperf3 -c "$server_ip" -t 5 | tail -n 4
    "$ln" --container ln-client --interface eth0 --rollback

    step "Timed rollback: rules remove themselves (--duration 15s)"
    "$ln" --container ln-client --interface eth0 --dst_ip "$server_ip" --latency 150 --duration 15s
    rtt
    sleep 17
    rtt

    step "Nothing left behind"
    "$ln" --check
}

down() { cleanup; "${compose[@]}" down; }

case "${1:-}" in
    up)  up ;;
    run) run ;;
    down) down ;;
    "") up; run ;;
    *) sed -n '3,7p' "$0"; exit 1 ;;
esac
