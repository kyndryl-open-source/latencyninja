#!/usr/bin/env bash
cd "$(dirname "$0")"
run() { echo; echo "\$ latencyninja $*"; timeout 10 ./latencyninja "$@" </dev/null 2>&1 | sed 's/^/    /'; echo "    rc=${PIPESTATUS[0]}"; }
reset() { ./latencyninja --rollback -i ln0 >/dev/null 2>&1; }
bash tests/netns_setup.sh up >/dev/null 2>&1
t() { out=$(tc qdisc add dev ln0 root netem "$@" 2>&1); rc=$?; tc qdisc del dev ln0 root 2>/dev/null; echo "netem $* -> rc=$rc ${out:0:80}"; }
echo "=== delay limits"
for v in 274000ms 274877ms 274878ms 274900ms 275000ms 300000ms; do t delay $v; done
t delay 100ms 274877ms; t delay 100ms 275000ms; t delay 274877ms 274877ms
echo "=== small and odd values"
t delay 0.0001ms; t delay 0.001ms; t delay 1e-07ms; t delay 5ms 1e-07ms; t loss 1e-07%; t loss 0.0000001%; t loss 100%; t loss 100.5%; t duplicate 100%; t corrupt 100%
echo "=== rates"
t delay 1ms rate 1bit; t delay 1ms rate 0.5bit; t delay 1ms rate 99999999999999999999mbit; t delay 1ms rate 10gbit; t delay 1ms rate 1000gbit; t delay 1ms rate 5000gbit; t delay 1ms rate 10mbps
echo "=== formats"
t delay 1.5ms; t delay 1.ms; t delay 5ms reorder 5%; t delay 5ms jitter 3ms
echo "=== query with ports"
reset; run -i ln0 -d 10.10.0.2:80 -l 5 -w egress | tail -3; run --query | grep -B1 -A6 "Device: lne-ln0"; reset
run -i ln0 -d 10.10.0.2:80 -l 5 -w ingress | tail -1; run --query | grep -A6 "Device: lni-ln0"; reset
echo "=== help as non root"
su nobody -s /bin/bash -c "./latencyninja --help" 2>&1 | head -2
echo "=== foreign root qdisc"
tc qdisc show dev ln0
echo "=== mq defaults on runner NIC"
tc qdisc show dev eth0 | head -3
