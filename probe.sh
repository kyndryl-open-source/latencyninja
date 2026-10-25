#!/usr/bin/env bash
cd "$(dirname "$0")"
run() { echo; echo "\$ latencyninja $*"; timeout 10 ./latencyninja "$@" </dev/null 2>&1 | sed 's/^/    /'; echo "    rc=${PIPESTATUS[0]}"; }
state() { echo "  -- state:"; tc qdisc show dev ln0 | sed 's/^/    ln0: /'; tc filter show dev ln0 2>/dev/null | grep -i redirect | sed 's/^/    ln0 filter: /'; ip -o link | grep -oE 'ln[ie]-[a-z0-9]+' | sed 's/^/    dev: /'; systemctl list-timers --all --no-legend 'latencyninja*' | sed 's/^/    timer: /'; }
reset() { ./latencyninja --rollback -i ln0 >/dev/null 2>&1; }
bash tests/netns_setup.sh up >/dev/null 2>&1
echo "=== 1 tc direct: reorder without delay"
tc qdisc add dev ln0 root netem reorder 5%; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
echo "=== 2 tc direct: scientific notation / huge values"
tc qdisc add dev ln0 root netem delay 1e-07ms; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
tc qdisc add dev ln0 root netem delay 49999999999999995805696ms; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
tc qdisc add dev ln0 root netem loss 1e-07%; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
tc qdisc add dev ln0 root netem delay 5ms rate 99999999999999999999mbit; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
tc qdisc add dev ln0 root netem delay 0.0001ms; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
tc qdisc add dev ln0 root netem delay 3600000ms; echo "rc=$?"; tc qdisc del dev ln0 root 2>/dev/null
echo "=== 3 failed apply leaves state? (reorder without latency)"
run -i ln0 -d 10.10.0.2 -k 5; state; run --check; reset
echo "=== 4 absurd value"
run -i ln0 -d 10.10.0.2 -l 0.0000001; state; reset
echo "=== 5 log dir missing with --duration"
run -i ln0 -d 10.10.0.2 -l 10 -t 5m --logging /nonexistent/x.log; state; reset
echo "=== 6 option without value (hang?)"
run --json; run -i ln0 -d 10.10.0.2 -l 5 --backup; run -i ln0 -d 10.10.0.2 -l 5 --logging
echo "=== 7 ping package"
dpkg -l | grep -E 'ping' | awk '{print $2}'
echo "=== 8 version as non-root"
su nobody -s /bin/bash -c "./latencyninja --version" 2>&1 | head -3
echo "=== 9 query shows ports"
run -i ln0 -d 10.10.0.2:80 -l 5 -w egress >/dev/null; run --query | sed -n 1,30p; reset
echo "=== 10 existing user qdisc is lost?"
tc qdisc replace dev ln0 root handle 5: htb default 1; tc qdisc show dev ln0
run -i ln0 -d 10.10.0.2 -l 5 -w egress >/dev/null; reset; tc qdisc show dev ln0
echo "=== 11 sub-millisecond halving"
run -i ln0 -d 10.10.0.2 -l 1234567.891 -w both | grep -i latency; tc qdisc show dev lne-ln0 | grep netem; reset
echo "=== 12 single interface long-name"
echo done
