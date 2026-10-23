#!/usr/bin/env bash
#
# Reboot persistence test, driven from the host by: tests/vm.sh reboot-test [ubuntu|fedora]
#
#   prepare  install the test topology as a boot service, apply --persist rules on ln0, bond0, wg0
#   verify   after a reboot, check the persisted rules were re-applied and are effective
#   cleanup  roll back the rules and remove the test topology service

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
ln="$repo_dir/latencyninja"
lib_dir="/usr/local/lib/latencyninja-test"
unit="/etc/systemd/system/latencyninja-testnet.service"
fail=0

check() {
    local desc="$1"; shift
    if "$@"; then echo "  ok   $desc"; else echo "  FAIL $desc"; fail=1; fi
}

avg_rtt() { ping -c 10 -i 0.05 -w 5 -q "$1" | grep -E 'min/avg' | sed 's/.*= //' | cut -d/ -f2; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }

case "${1:-}" in
    prepare)
        # The repo mount may not be ready when the topology is built at boot, so use a local copy
        mkdir -p "$lib_dir/helpers"
        cp "$repo_dir/tests/netns_setup.sh" "$lib_dir/"
        cp "$repo_dir/tests/helpers/"*.py "$lib_dir/helpers/"
        cat > "$unit" <<EOF
[Unit]
Description=Latency Ninja test topology
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $lib_dir/netns_setup.sh up

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now latencyninja-testnet.service
        "$ln" -i ln0 -d 10.10.0.3 -l 100 --persist </dev/null >/dev/null || fail=1
        "$ln" -i bond0 -d 10.40.0.2 -l 60 --persist </dev/null >/dev/null || fail=1
        "$ln" -i wg0 -d 10.30.0.2 -l 40 -w egress --persist </dev/null >/dev/null || fail=1
        # Inside a namespace: re-applied at boot by the watcher service
        "$ln" --netns lnpeer -i wgp0 -d 10.30.0.1 -l 20 -w egress --persist </dev/null >/dev/null || fail=1
        "$ln" --query </dev/null | tail -1
        ;;
    verify)
        echo "Uptime: $(uptime -p)"
        for i in $(seq 1 120); do
            tc qdisc show dev ln0 2>/dev/null | grep -q 'prio 1:' && \
            tc qdisc show dev bond0 2>/dev/null | grep -q 'prio 1:' && \
            tc qdisc show dev wg0 2>/dev/null | grep -q 'prio 1:' && \
            nsenter --net=/run/netns/lnpeer tc qdisc show dev wgp0 2>/dev/null | grep -q 'prio 1:' && break
            sleep 0.5
        done
        sleep 2
        for i in ln0 bond0 wg0; do
            check "latencyninja@$i ran at boot" systemctl is-active -q "latencyninja@$i.service"
        done
        r=$(avg_rtt 10.10.0.3); check "ln0 rule effective: 10.10.0.3 ~100ms (got $r)" between "$r" 90 140
        r=$(avg_rtt 10.10.0.2); check "ln0 rule targeted: 10.10.0.2 unaffected (got $r)" between "$r" 0 10
        r=$(avg_rtt 10.40.0.2); check "bond0 rule effective: ~60ms (got $r)" between "$r" 55 90
        check "namespace watcher running" systemctl is-active -q latencyninja-namespaces.service
        r=$(avg_rtt 10.30.0.2); check "wg0 (40ms) + namespace wgp0 (20ms) rules effective: ~60ms (got $r)" between "$r" 57 90
        [ "$fail" -eq 0 ] && echo "Reboot persistence: PASSED" || echo "Reboot persistence: FAILED"
        ;;
    cleanup)
        for i in ln0 bond0 wg0; do "$ln" -r -i "$i" </dev/null >/dev/null; done
        "$ln" --netns lnpeer -r -i wgp0 </dev/null >/dev/null
        systemctl disable --now latencyninja-testnet.service &>/dev/null
        bash "$lib_dir/netns_setup.sh" down
        rm -rf "$unit" "$lib_dir"
        systemctl daemon-reload
        ;;
    *)
        echo "Usage: $0 prepare|verify|cleanup"; exit 1 ;;
esac
exit "$fail"
