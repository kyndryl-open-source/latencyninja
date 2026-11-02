#!/usr/bin/env bash
#
# Functional test suite for Latency Ninja. Run as root inside a disposable Linux VM:
#
#   sudo bash tests/run_tests.sh            # all tests
#   sudo bash tests/run_tests.sh latency    # only tests whose name contains "latency"
#
# Uses the topology from tests/netns_setup.sh (ln0, bond0 and wg0 <-> lnpeer namespace) so
# the VM's real interfaces are never touched.

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
tests_dir="$repo_dir/tests"
filter="${1:-}"
dev="ln0"
work_dir="/tmp/lntest"
pass=0 fail=0 skip=0
failed_tests=()

# ---------- helpers ----------

red() { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow() { printf '\033[33m%s\033[0m' "$*"; }

# Run latencyninja from the repo dir. Output is stored in $out and the exit code in $rc.
ln() {
    out=$(cd "$repo_dir" && timeout 300 ./latencyninja "$@" </dev/null 2>&1)
    rc=$?
}

# Roll back (and unpersist) every interface the tests may touch
rollback() {
    local i
    for i in "$dev" bond0 wg0 ln-hy lnverylongif01; do
        ip link show "$i" &>/dev/null || continue
        (cd "$repo_dir" && ./latencyninja --rollback --interface "$i" </dev/null >/dev/null 2>&1)
    done
    # Rules applied inside the peer namespace by the namespace tests
    for i in $(nsenter --net=/run/netns/lnpeer ip -o link show 2>/dev/null | awk -F': ' '/ ln[ie]-/ {print $2}' | sed 's/^ln[ie]-//; s/@.*//' | sort -u); do
        (cd "$repo_dir" && ./latencyninja --netns lnpeer --rollback --interface "$i" </dev/null >/dev/null 2>&1)
    done
}

# Container runtime available for the container tests (docker or podman), empty if none
container_runtime() {
    local r
    for r in docker podman; do
        command -v "$r" &>/dev/null && "$r" info &>/dev/null && { echo "$r"; return; }
    done
}

# Wait up to 10s until Latency Ninja rules are attached to an interface
wait_for_rules() {
    local i
    for i in $(seq 1 40); do
        tc qdisc show dev "$1" 2>/dev/null | grep -q 'prio 1:' && return 0
        sleep 0.25
    done
    return 1
}

# Ping stats: sets $avg, $min, $max, $mdev (ms), $loss (%) and $dups
ping_stats() {
    local target="$1" count="${2:-20}" interval="${3:-0.02}" raw summary
    # -W: ping otherwise waits 10s for the replies that were lost, even when nothing is coming
    raw=$(ping -c "$count" -i "$interval" -W 2 -w $((count / 5 + 5)) "$target" 2>&1)
    summary=$(grep -E 'min/avg/max' <<< "$raw" | sed 's/.*= //; s/ ms.*//')
    IFS=/ read -r min avg max mdev <<< "${summary:-0/0/0/0}"
    loss=$(grep -oE '[0-9.]+% packet loss' <<< "$raw" | cut -d% -f1)
    dups=$(grep -c 'DUP!' <<< "$raw")
}

tcp_rtt() { python3 "$tests_dir/helpers/tcp_rtt.py" "$1" "$2" "${3:-10}"; }

# Throughput in Mbit/s: throughput HOST upload|download [SECONDS]
throughput() { python3 "$tests_dir/helpers/throughput.py" "$1" "$2" "${3:-4}"; }

# Wait up to N seconds (default 15) until an interface has no Latency Ninja rules
wait_for_no_rules() {
    local i
    for i in $(seq 1 $(( ${2:-15} * 4 ))); do
        tc qdisc show dev "$1" 2>/dev/null | grep -q 'prio 1:' || return 0
        sleep 0.25
    done
    return 1
}

# Float comparison: between VALUE LOW HIGH
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }

current_test=""
test_ok=1
check() {
    # check "description" command...
    local desc="$1"; shift
    if "$@"; then
        printf '    %s %s\n' "$(green ok)" "$desc"
    else
        printf '    %s %s\n' "$(red FAIL)" "$desc"
        test_ok=0
    fi
}

contains() { grep -qF -- "$2" <<< "$1"; }
not() { ! "$@"; }
not_contains() { ! grep -qF -- "$2" <<< "$1"; }

run_test() {
    local name="$1"
    [ -n "$filter" ] && [ "$filter" != "@quick" ] && [[ "$name" != *"$filter"* ]] && return
    current_test="$name"
    test_ok=1
    out=""
    printf '%s\n' "$(yellow "▶ $name")"
    local started=$SECONDS
    rollback
    "test_$name"
    local status=$?
    rollback
    printf '    (%ss)\n' "$((SECONDS - started))"
    if [ "$status" -eq 77 ]; then
        skip=$((skip + 1))
        printf '    %s\n' "$(yellow SKIPPED)"
    elif [ "$test_ok" -eq 1 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_tests+=("$name")
        [ -n "$out" ] && printf '    last output:\n%s\n' "$(sed 's/^/      | /' <<< "$out" | tail -15)"
    fi
}

# Print bond diagnostics (used when bond connectivity is unexpectedly lost)
bond_diag() {
    local p=(nsenter --net=/run/netns/lnpeer)
    echo "    DIAG bond0 mac $(cat /sys/class/net/bond0/address), active $(awk '/Currently Active/ {print $4}' /proc/net/bonding/bond0)"
    "${p[@]}" ip neigh show 10.40.0.1 | sed 's/^/      peer-neigh /'
    ip neigh show dev bond0 | sed 's/^/      neigh /'
    "${p[@]}" bridge fdb show br lnbr0 | grep -v permanent | sed 's/^/      fdb /'
    tc -s qdisc show dev bond0 | sed 's/^/      bond0 /'
    tc -s filter show dev bond0 | sed 's/^/      bond0-filter /'
    ip -br link | grep -E 'bond0|lnb|ln[ie]-bond' | sed 's/^/      /'
    tc -s qdisc show dev lne-bond0 2>&1 | sed 's/^/      lne /'
    tc -s qdisc show dev lni-bond0 2>&1 | sed 's/^/      lni /'
    journalctl --since "-30s" --no-pager -o short-precise | grep -E 'latencyninja@bond0|bond0|lnb' | tail -15 | sed 's/^/      /'
}

# ---------- tests: CLI basics ----------

test_cli_version() {
    ln --version
    check "exit code 0" [ "$rc" -eq 0 ]
    check "reports version from version.txt ($(cat "$repo_dir/version.txt"))" contains "$out" "$(cat "$repo_dir/version.txt")"
}

test_cli_help() {
    ln --help
    check "exit code 0" [ "$rc" -eq 0 ]
    check "shows usage" contains "$out" "--interface"
    check "documents --backup" contains "$out" "--backup"
    check "documents --logging" contains "$out" "--logging"
    ln --about
    check "--about exit code 0" [ "$rc" -eq 0 ]
}

test_cli_requires_root() {
    [ -z "${SUDO_USER:-}" ] && return 77
    out=$(cd "$repo_dir" && sudo -u "$SUDO_USER" ./latencyninja --version 2>&1); rc=$?
    check "non-root is rejected" [ "$rc" -ne 0 ]
    check "explains root is required" contains "$out" "must be run as root"
}

# ---------- tests: validation ----------

test_validation_errors() {
    ln --interface doesnotexist --dst_ip 10.10.0.2 --latency 10
    check "invalid interface rejected" contains "$out" "Invalid interface"
    ln --interface "$dev" --dst_ip 10.10.0.2
    check "no perturbation parameter rejected" contains "$out" "At least one of the parameters"
    ln --interface "$dev" --dst_ip 10.10.0.2 --jitter 5
    check "jitter without latency rejected" contains "$out" "Jitter can only be used with latency"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --direction sideways
    check "invalid direction rejected" contains "$out" "Invalid direction"
    ln --interface "$dev" --dst_ip 10.10.0 --latency 10
    check "invalid IP rejected" contains "$out" "Invalid dst_ip format"
    ln --interface "$dev" --dst_ip 10.10.0.2:70000 --latency 10
    check "invalid port rejected" contains "$out" "not in the range"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 0
    check "zero latency rejected" contains "$out" "positive numeric value"
    ln --rollback
    check "rollback without interface rejected" contains "$out" "requires the -i|--interface"
    ln --bogus
    check "unknown option rejected" contains "$out" "Invalid option"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --backup /nonexistent/dir
    check "missing backup dir rejected" contains "$out" "Backup directory does not exist"
    check "nothing applied after failed backup" not_contains "$(tc qdisc show dev $dev)" "netem"
}

# ---------- tests: perturbations ----------

test_latency_both() {
    ping_stats 10.10.0.3; local base="$avg"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "netem on lni-$dev (ingress) with 50ms" contains "$(tc qdisc show dev lni-$dev)" "delay 50ms"
    check "netem on lne-$dev (egress) with 50ms" contains "$(tc qdisc show dev lne-$dev)" "delay 50ms"
    ping_stats 10.10.0.2
    check "RTT to target ~100ms (got $avg)" between "$avg" 90 130
    ping_stats 10.10.0.3
    check "RTT to non-target unaffected (got $avg, base $base)" between "$avg" 0 10
}

test_latency_egress() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "netem on lne-$dev with full 100ms" contains "$(tc qdisc show dev lne-$dev)" "delay 100ms"
    check "no ingress ifb created" not_contains "$(ip link show)" "lni-$dev"
    ping_stats 10.10.0.2
    check "RTT ~100ms (got $avg)" between "$avg" 90 130
}

test_latency_ingress() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --direction ingress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "netem on lni-$dev with full 100ms" contains "$(tc qdisc show dev lni-$dev)" "delay 100ms"
    check "no egress ifb created" not_contains "$(ip link show)" "lne-$dev"
    ping_stats 10.10.0.2
    check "RTT ~100ms (got $avg)" between "$avg" 90 130
}

test_jitter() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --jitter 40
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2 40
    check "RTT avg ~100ms (got $avg)" between "$avg" 80 140
    check "RTT stddev > 5ms (got $mdev)" between "$mdev" 5 1000
}

test_packet_loss() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 30 --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2 200 0.01
    check "loss roughly 30% (got $loss%)" between "$loss" 15 45
    ping_stats 10.10.0.3 50 0.01
    check "non-target has no loss (got $loss%)" between "$loss" 0 0
}

test_duplicate() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --duplicate 50 --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2 100 0.01
    check "duplicate replies seen (got $dups)" between "$dups" 20 80
}

test_corrupt() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --corrupt 50 --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "netem corrupt configured" contains "$(tc qdisc show dev lne-$dev)" "corrupt 50%"
    ping_stats 10.10.0.2 100 0.01
    check "corrupted packets cause loss (got $loss%)" between "$loss" 15 85
}

test_reorder() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --reorder 50 --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "netem reorder configured" contains "$(tc qdisc show dev lne-$dev)" "reorder 50%"
    ping_stats 10.10.0.2 50 0.01
    check "some packets bypass delay (min $min ms)" between "$min" 0 20
    check "some packets delayed (max $max ms)" between "$max" 90 1000
}

test_combined() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 60 --jitter 10 --packet_loss 5 --duplicate 5 --corrupt 1 --reorder 5
    check "apply exit code 0" [ "$rc" -eq 0 ]
    local q; q=$(tc qdisc show dev lne-$dev)
    for p in "delay 30ms" "loss 5%" "duplicate 5%" "corrupt 1%" "reorder 5%"; do
        check "lne-$dev has '$p'" contains "$q" "$p"
    done
}

# ---------- tests: targeting ----------

test_target_ports() {
    ln --interface "$dev" --dst_ip 10.10.0.2:8080~443 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    local t
    t=$(tcp_rtt 10.10.0.2 8080); check "TCP 8080 delayed ~100ms (got $t)" between "$t" 90 140
    t=$(tcp_rtt 10.10.0.2 443);  check "TCP 443 delayed ~100ms (got $t)" between "$t" 90 140
    t=$(tcp_rtt 10.10.0.2 9090); check "TCP 9090 unaffected (got $t)" between "$t" 0 10
    ping_stats 10.10.0.2;        check "ICMP to same host unaffected (got $avg)" between "$avg" 0 10
}

test_target_multiple() {
    ln --interface "$dev" --dst_ip 10.10.0.2,10.10.0.3:80,10.20.0.0/24 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2;  check "10.10.0.2 delayed (got $avg)" between "$avg" 90 130
    ping_stats 10.20.0.1;  check "10.20.0.0/24 subnet delayed (got $avg)" between "$avg" 90 130
    ping_stats 10.10.0.4;  check "10.10.0.4 unaffected (got $avg)" between "$avg" 0 10
    local t
    t=$(tcp_rtt 10.10.0.3 80);   check "10.10.0.3:80 delayed (got $t)" between "$t" 90 140
    t=$(tcp_rtt 10.10.0.3 9090); check "10.10.0.3:9090 unaffected (got $t)" between "$t" 0 10
}

test_target_src_only() {
    # Only --src_ip given: dst defaults to the interface IP and the perspective is swapped
    ln --interface "$dev" --src_ip 10.10.0.2 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2; check "traffic with 10.10.0.2 delayed (got $avg)" between "$avg" 90 130
    ping_stats 10.10.0.3; check "traffic with 10.10.0.3 unaffected (got $avg)" between "$avg" 0 10
}

test_target_src_and_dst() {
    ln --interface "$dev" --src_ip 10.10.0.1 --dst_ip 10.10.0.4 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.4; check "10.10.0.4 delayed (got $avg)" between "$avg" 90 130
    ping_stats 10.10.0.2; check "10.10.0.2 unaffected (got $avg)" between "$avg" 0 10
}

test_target_src_wrong() {
    # A source filter that doesn't match our address must not affect traffic
    ln --interface "$dev" --src_ip 10.99.0.1 --dst_ip 10.10.0.2 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2; check "10.10.0.2 unaffected (got $avg)" between "$avg" 0 10
}

# ---------- tests: JSON ----------

test_json_import() {
    mkdir -p "$work_dir"
    cat > "$work_dir/test.json" <<EOF
{ "interface": "$dev", "dst_ip": "10.10.0.2,10.10.0.3:8080", "direction": "egress",
  "latency": "100", "packet_loss": "1" }
EOF
    ln --json "$work_dir/test.json"
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "egress netem 100ms + loss" contains "$(tc qdisc show dev lne-$dev)" "delay 100ms loss 1%"
    ping_stats 10.10.0.2; check "10.10.0.2 delayed (got $avg)" between "$avg" 90 140
    local t; t=$(tcp_rtt 10.10.0.3 8080); check "10.10.0.3:8080 delayed (got $t)" between "$t" 90 150
}

# ---------- tests: query / rollback ----------

test_query() {
    ln --interface "$dev" --dst_ip 10.10.0.2:8080,10.20.0.0/24 --latency 40 --jitter 4
    ln --query
    check "exit code 0" [ "$rc" -eq 0 ]
    check "lists lne-$dev" contains "$out" "Device: lne-$dev"
    check "no bogus bonding_masters device" not_contains "$out" "bonding_masters"
    check "shows host filter" contains "$out" "dst_ip: 10.10.0.2/32"
    check "shows subnet filter" contains "$out" "dst_ip: 10.20.0.0/24"
    check "shows port" contains "$out" "dst_port: 8080"
    check "shows netem delay" contains "$out" "netem: delay 20ms"
}

test_rollback() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    ln --rollback --interface "$dev"
    check "exit code 0" [ "$rc" -eq 0 ]
    check "confirms rollback" contains "$out" "Rolled back"
    check "ifb interfaces removed" not_contains "$(ip link show)" "-$dev:"
    check "no netem left on $dev" not_contains "$(tc qdisc show dev $dev)" "ingress"
    ping_stats 10.10.0.2; check "latency gone (got $avg)" between "$avg" 0 10
}

test_reapply_replaces() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 200
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 100
    check "second apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2; check "old rule removed (got $avg)" between "$avg" 0 10
    ping_stats 10.10.0.3; check "new rule active (got $avg)" between "$avg" 90 130
}

# ---------- tests: backup and logging ----------

test_backup_and_logging() {
    rm -rf "$work_dir/bk" "$work_dir/ln.log"; mkdir -p "$work_dir/bk"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 30 --backup "$work_dir/bk" --logging "$work_dir/ln.log"
    check "apply exit code 0" [ "$rc" -eq 0 ]
    local bk; bk=$(ls "$work_dir"/bk/latencyninja_tc_backup_* 2>/dev/null | head -1)
    check "backup file created" [ -n "$bk" ]
    check "backup has previous rules section" contains "$(cat "$bk" 2>/dev/null)" "### Previous TC Rules ###"
    check "backup has applied values" contains "$(cat "$bk" 2>/dev/null)" "Latency: 30ms"
    check "output mentions backup path" contains "$out" "Backup saved to: $bk"
    check "log file created" [ -f "$work_dir/ln.log" ]
    local log; log=$(cat "$work_dir/ln.log" 2>/dev/null)
    check "log has start/complete markers" contains "$log" "Execution Complete"
    check "log records parameters" contains "$log" "Latency: 30ms"
    check "log records egress rule" contains "$log" "Egress (lne-$dev)"

    # A second run should capture the first run's rules as "previous"
    sleep 1
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 10 --backup "$work_dir/bk" --logging "$work_dir/ln.log"
    bk=$(ls -t "$work_dir"/bk/latencyninja_tc_backup_* | head -1)
    check "second backup captured previous netem" contains "$(cat "$bk")" "delay 15ms"
    check "log appended (2 entries)" [ "$(grep -c 'Execution Start' "$work_dir/ln.log")" -eq 2 ]
}

test_backup_defaults() {
    local before; before=$(ls /tmp/latencyninja_tc_backup_* 2>/dev/null | wc -l)
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10
    local after; after=$(ls /tmp/latencyninja_tc_backup_* 2>/dev/null | wc -l)
    check "default backup written to /tmp" [ "$after" -gt "$before" ]
    check "default log in /var/log/latencyninja" [ -f /var/log/latencyninja/latencyninja.log ]
    check "default log is not world readable" [ "$(stat -c %a /var/log/latencyninja/latencyninja.log)" = "640" ]
    check "nothing is logged to /tmp by default" [ ! -s /tmp/latencyninja.log ] || [ /tmp/latencyninja.log -ot /var/log/latencyninja/latencyninja.log ]
}

test_failed_apply_not_logged() {
    # If tc setup fails the run must not be reported/logged as applied
    rm -f "$work_dir/fail.log"; mkdir -p "$work_dir"
    ln_failing_tc --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --direction ingress --logging "$work_dir/fail.log"
    check "failed apply returns non-zero" [ "$rc" -ne 0 ]
    check "failed apply not logged" [ ! -s "$work_dir/fail.log" ]
}

# ---------- tests: bonded and WireGuard interfaces ----------

test_bond_directions() {
    local d
    for d in both ingress egress; do
        ln --interface bond0 --dst_ip 10.40.0.2 --latency 100 --direction "$d"
        check "$d: apply exit code 0" [ "$rc" -eq 0 ]
        ping_stats 10.40.0.2; check "$d: RTT ~100ms (got $avg)" between "$avg" 90 130
    done
}

test_bond_ports_and_failover() {
    # Sanity check of the test topology: active-backup slaves must share the bond's MAC address
    local bond_mac; bond_mac=$(cat /sys/class/net/bond0/address)
    check "bond members share the bond MAC" [ "$(cat /sys/class/net/lnb0/address)" = "$bond_mac" -a "$(cat /sys/class/net/lnb1/address)" = "$bond_mac" ]
    ln --interface bond0 --dst_ip 10.40.0.2:8080 --latency 100
    local t
    t=$(tcp_rtt 10.40.0.2 8080); check "TCP 8080 delayed (got $t)" between "$t" 90 140
    t=$(tcp_rtt 10.40.0.2 9090); check "TCP 9090 unaffected (got $t)" between "$t" 0 10
    # Fail the active slave: rules live on the bond, so they must keep working on the backup slave
    local active; active=$(awk '/Currently Active Slave/ {print $4}' /proc/net/bonding/bond0)
    ip link set "$active" down; sleep 1
    local now; now=$(awk '/Currently Active Slave/ {print $4}' /proc/net/bonding/bond0)
    check "bond failed over ($active -> $now)" [ "$now" != "$active" ]
    t=$(tcp_rtt 10.40.0.2 8080); check "TCP 8080 still delayed after failover (got $t)" between "$t" 90 140
    if [ "$t" = "-1" ]; then
        echo "    DIAG:"; grep -E "Currently Active|Slave Interface|MII Status" /proc/net/bonding/bond0 | sed 's/^/      /'
        nsenter --net=/run/netns/lnpeer bridge fdb show br lnbr0 | grep -v permanent | sed 's/^/      fdb /'
        nsenter --net=/run/netns/lnpeer ip neigh | sed 's/^/      peer-neigh /'
        ip neigh show dev bond0 | sed 's/^/      neigh /'
        ip -br link | grep -E "bond0|lnb" | sed 's/^/      /'
        nsenter --net=/run/netns/lnpeer ip -br link | sed 's/^/      peer /'
        tc -s qdisc show dev bond0 | sed 's/^/      /'
        journalctl --since "-15s" --no-pager | grep -E "lnb|bond0" | tail -6 | sed 's/^/      /'
    fi
    ip link set "$active" up; sleep 0.5
}

test_wireguard_directions() {
    local d
    for d in both ingress egress; do
        ln --interface wg0 --dst_ip 10.30.0.2 --latency 100 --direction "$d"
        check "$d: apply exit code 0" [ "$rc" -eq 0 ]
        ping_stats 10.30.0.2; check "$d: RTT ~100ms (got $avg)" between "$avg" 90 130
    done
}

test_wireguard_ports_and_loss() {
    ln --interface wg0 --dst_ip 10.30.0.2:8080 --latency 100
    local t
    t=$(tcp_rtt 10.30.0.2 8080); check "TCP 8080 through tunnel delayed (got $t)" between "$t" 90 140
    t=$(tcp_rtt 10.30.0.2 9090); check "TCP 9090 through tunnel unaffected (got $t)" between "$t" 0 10
    ping_stats 10.10.0.2; check "underlay ln0 unaffected (got $avg)" between "$avg" 0 10
    ln --interface wg0 --dst_ip 10.30.0.2 --packet_loss 30 --direction egress
    ping_stats 10.30.0.2 200 0.01; check "loss through tunnel ~30% (got $loss%)" between "$loss" 15 45
}

test_multi_interface() {
    # Each interface has its own ifb devices, so shaping one must not break another
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 100
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 60
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 30 --direction egress
    ping_stats 10.10.0.3; check "ln0 rule still active (got $avg)" between "$avg" 90 130
    ping_stats 10.40.0.2; check "bond0 rule active (got $avg)" between "$avg" 55 80
    ping_stats 10.30.0.2; check "wg0 rule active (got $avg)" between "$avg" 28 50
    ln --rollback --interface bond0
    ping_stats 10.10.0.3; check "ln0 unaffected by bond0 rollback (got $avg)" between "$avg" 90 130
    ping_stats 10.40.0.2; check "bond0 rolled back (got $avg)" between "$avg" 0 10
}

test_interface_names() {
    # Hyphenated and long names (ifb names are limited to 15 characters)
    ip netns exec lnpeer true || return 77
    ip link add ln-hy type veth peer name lnhyp; ip link set lnhyp netns lnpeer
    ip link add lnverylongif01 type veth peer name lnlongp; ip link set lnlongp netns lnpeer
    ip addr add 10.60.0.1/24 dev ln-hy; ip link set ln-hy up
    ip addr add 10.70.0.1/24 dev lnverylongif01; ip link set lnverylongif01 up
    ip -n lnpeer addr add 10.60.0.2/24 dev lnhyp; ip -n lnpeer link set lnhyp up
    ip -n lnpeer addr add 10.70.0.2/24 dev lnlongp; ip -n lnpeer link set lnlongp up

    ln --interface ln-hy --dst_ip 10.60.0.2 --latency 100 --persist
    check "hyphenated: apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.60.0.2; check "hyphenated: RTT ~100ms (got $avg)" between "$avg" 90 130
    ln --interface lnverylongif01 --dst_ip 10.70.0.2 --latency 100
    check "long name: apply exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.70.0.2; check "long name: RTT ~100ms (got $avg)" between "$avg" 90 130

    # Re-create the hyphenated interface: its persisted rules must come back
    ip link delete ln-hy; ip link add ln-hy type veth peer name lnhyp; ip link set lnhyp netns lnpeer
    ip addr add 10.60.0.1/24 dev ln-hy; ip link set ln-hy up
    ip -n lnpeer addr add 10.60.0.2/24 dev lnhyp; ip -n lnpeer link set lnhyp up
    check "hyphenated: persisted rules re-applied" wait_for_rules ln-hy

    rollback
    ip link delete ln-hy; ip link delete lnverylongif01
}

test_multiple_addresses() {
    ip addr add 10.10.0.11/24 dev "$dev"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "uses the first address as source" contains "$out" "Source IP/Network: 10.10.0.1:0"
    ip addr del 10.10.0.11/24 dev "$dev"
}

test_run_from_other_dir() {
    out=$(cd / && "$repo_dir/latencyninja" --version </dev/null 2>&1); rc=$?
    check "runs from / (exit $rc)" [ "$rc" -eq 0 ]
    check "reports version" contains "$out" "$(cat "$repo_dir/version.txt")"
}

# ---------- tests: snapshots ----------

test_snapshot_save_restore() {
    mkdir -p "$work_dir"; rm -f "$work_dir/snap"
    # ln0 rules avoid 10.10.0.2, the wg0 tunnel endpoint
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 100
    ln --interface bond0 --dst_ip 10.40.0.2:8080 --latency 60 --direction egress
    ln --save "$work_dir/snap"
    check "save exit code 0" [ "$rc" -eq 0 ]
    check "snapshot lists both interfaces" contains "$out" "bond0 ln0"

    # Change everything, then restore
    ln --rollback --interface bond0
    ln --interface "$dev" --dst_ip 10.10.0.4 --latency 20
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 30
    ln --restore "$work_dir/snap"
    check "restore exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.3; check "ln0 rule restored (got $avg)" between "$avg" 90 130
    ping_stats 10.10.0.4; check "ln0 newer rule gone (got $avg)" between "$avg" 0 10
    local t; t=$(tcp_rtt 10.40.0.2 8080); check "bond0 port rule restored (got $t)" between "$t" 55 90
    check "bond0 direction restored (egress only)" not_contains "$(ip link show)" "lni-bond0"
    ping_stats 10.30.0.2; check "wg0 (not in snapshot) rolled back (got $avg)" between "$avg" 0 10
}

test_snapshot_scoped() {
    mkdir -p "$work_dir"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 60
    ln --save "$work_dir/snap-all"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 20
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 20
    ln --restore "$work_dir/snap-all" --interface bond0
    check "scoped restore exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.40.0.2; check "bond0 restored (got $avg)" between "$avg" 55 80
    ping_stats 10.10.0.2; check "ln0 left alone (got $avg)" between "$avg" 18 35
}

test_snapshot_clean_state() {
    mkdir -p "$work_dir"
    ln --save "$work_dir/snap-clean"
    check "snapshot of clean state" contains "$out" "Interfaces with rules: none"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 100
    ln --restore "$work_dir/snap-clean"
    check "restore exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2; check "ln0 rolled back (got $avg)" between "$avg" 0 10
    ping_stats 10.30.0.2; check "wg0 rolled back (got $avg)" between "$avg" 0 10
}

test_snapshot_restore_backup() {
    # Every apply writes a backup snapshot of the previous state, which can be restored to undo it
    rm -rf "$work_dir/bk2"; mkdir -p "$work_dir/bk2"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --backup "$work_dir/bk2"
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 30 --backup "$work_dir/bk2"
    local bk; bk=$(grep -o "$work_dir/bk2/latencyninja_tc_backup_[0-9_]*" <<< "$out" | head -1)
    check "output shows restore command" contains "$out" "--restore $bk"
    ln --restore "$bk"
    check "restore exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2; check "previous rule back (got $avg)" between "$avg" 90 130
    ping_stats 10.10.0.3; check "last rule undone (got $avg)" between "$avg" 0 10
}

test_snapshot_errors() {
    ln --restore /nonexistent/snap
    check "missing file rejected" contains "$out" "Snapshot file not found"
    mkdir -p "$work_dir"; echo "hello" > "$work_dir/notasnap"
    ln --restore "$work_dir/notasnap"
    check "foreign file rejected" contains "$out" "Not a Latency Ninja snapshot"
    ln --save /nonexistent/dir/snap
    check "bad save path rejected" contains "$out" "Snapshot directory does not exist"
    printf '# Latency Ninja snapshot\n[scope all]\n[interface ln0]\n--interface\nln0\n--dst_ip\n10.10.0.2\n--latency\n10\n--direction\n$(touch /tmp/lntest-pwned)\n[end]\n' > "$work_dir/evil"
    ln --restore "$work_dir/evil"
    check "snapshot content is never executed" [ ! -e /tmp/lntest-pwned ]
    rm -f /tmp/lntest-pwned
    printf '# Latency Ninja snapshot\n[scope all]\n[interface ln0]\n--restore\n%s\n[end]\n' "$work_dir/loop" > "$work_dir/loop"
    ln --restore "$work_dir/loop"
    check "options other than rule options are refused" contains "$out" "invalid saved arguments"
}

# ---------- tests: persistence ----------

test_persist_wireguard_recreate() {
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 100 --persist
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "reports persistence" contains "$out" "Persisted: rules for wg0"
    check "query lists persisted interface" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "Persisted interfaces: wg0"
    ip link set wg0 down; ip link set wg0 up; sleep 0.5
    ping_stats 10.30.0.2; check "rules survive link down/up (got $avg)" between "$avg" 90 130
    local n
    for n in 1 2; do
        bash "$tests_dir/netns_setup.sh" wg-recreate
        check "re-create #$n: rules re-applied" wait_for_rules wg0
        sleep 0.3
        ping_stats 10.30.0.2; check "re-create #$n: RTT ~100ms (got $avg)" between "$avg" 90 130
    done
}

test_persist_bond_recreate() {
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 60 --persist
    check "apply exit code 0" [ "$rc" -eq 0 ]
    bash "$tests_dir/netns_setup.sh" bond-recreate
    check "rules re-applied after re-create" wait_for_rules bond0
    local bond_mac; bond_mac=$(cat /sys/class/net/bond0/address)
    check "re-created bond members share the bond MAC" [ "$(cat /sys/class/net/lnb0/address)" = "$bond_mac" -a "$(cat /sys/class/net/lnb1/address)" = "$bond_mac" ]
    sleep 2   # the peer has to learn the new bond MAC address
    ping_stats 10.40.0.2; check "RTT ~60ms (got $avg)" between "$avg" 55 80
    between "$avg" 55 80 || bond_diag
}

test_persist_rollback_removes() {
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 100 --persist
    ln --rollback --interface wg0
    check "rollback reports removal" contains "$out" "Removed persisted rules for wg0"
    check "persisted args removed" [ ! -f /etc/latencyninja/persist/wg0.args ]
    bash "$tests_dir/netns_setup.sh" wg-recreate
    sleep 3
    check "no rules after re-create" not_contains "$(tc qdisc show dev wg0)" "prio"
}

test_persist_update_and_note() {
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 100 --persist
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 20
    check "non-persisted change warns about persisted rules" contains "$out" "different persisted rules"
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 50 --persist
    check "persisted rules updated" contains "$(cat /etc/latencyninja/persist/wg0.args)" "50"
    bash "$tests_dir/netns_setup.sh" wg-recreate
    wait_for_rules wg0; sleep 0.3
    ping_stats 10.30.0.2; check "updated rules re-applied (got $avg)" between "$avg" 45 70
}

test_persist_restore_keeps_persistence() {
    mkdir -p "$work_dir"
    ln --save "$work_dir/snap-empty"
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 100 --persist
    ln --restore "$work_dir/snap-empty"
    check "restore notes persisted rules" contains "$out" "has persisted rules"
    check "persistence kept" [ -f /etc/latencyninja/persist/wg0.args ]
}

# ---------- tests: bandwidth rate ----------
# netem queues up to 1000 packets, so measure a single direction per applied rule

test_rate_egress() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate 2mbit --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "netem rate configured" contains "$(tc qdisc show dev lne-$dev)" "rate 2Mbit"
    local t; t=$(throughput 10.10.0.2 upload); check "upload ~2 Mbit/s (got $t)" between "$t" 1.6 2.2
    t=$(throughput 10.10.0.3 upload 2); check "other host unaffected (got $t Mbit/s)" between "$t" 50 1000000
}

test_rate_ingress() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate 2mbit --direction ingress
    local t; t=$(throughput 10.10.0.2 download); check "download ~2 Mbit/s (got $t)" between "$t" 1.6 2.2
}

test_rate_both_directions() {
    # The rate applies to each direction (it isn't split like latency)
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate 5mbit
    check "rate not halved on ingress" contains "$(tc qdisc show dev lni-$dev)" "rate 5Mbit"
    check "rate not halved on egress" contains "$(tc qdisc show dev lne-$dev)" "rate 5Mbit"
    local t; t=$(throughput 10.10.0.2 download); check "download ~5 Mbit/s (got $t)" between "$t" 4 5.5
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate 5mbit
    t=$(throughput 10.10.0.2 upload); check "upload ~5 Mbit/s (got $t)" between "$t" 4 5.5
}

test_rate_port_and_units() {
    ln --interface "$dev" --dst_ip 10.10.0.2:5001 --rate 512kbit --direction egress
    local t; t=$(throughput 10.10.0.2 upload); check "port 5001 ~0.5 Mbit/s (got $t)" between "$t" 0.4 0.56
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate 1mbps --direction egress
    check "bytes/s unit accepted" contains "$(tc qdisc show dev lne-$dev)" "rate 8Mbit"
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate 2mbit --latency 50
    check "rate combined with latency" contains "$(tc qdisc show dev lne-$dev)" "delay 25ms rate 2Mbit"
    ln --query
    check "query shows rate" contains "$out" "rate 2Mbit"
}

test_rate_validation() {
    local bad
    for bad in 5 2mb fast 0mbit; do
        ln --interface "$dev" --dst_ip 10.10.0.2 --rate "$bad"
        check "rate '$bad' rejected" contains "$out" "Invalid rate format"
    done
    ln --interface "$dev" --dst_ip 10.10.0.2 --rate -1mbit
    check "negative rate rejected" contains "$out" "The --rate option requires an argument"
    check "nothing applied" not_contains "$(tc qdisc show dev $dev)" "prio"
}

# ---------- tests: profiles ----------

test_profile_apply() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile 4g
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "output names the profile" contains "$out" "Profile: 4g"
    local q; q=$(tc qdisc show dev lne-$dev)
    check "4g values applied (delay 30ms each way)" contains "$q" "delay 30ms"
    check "4g rate applied" contains "$q" "rate 20Mbit"
    check "4g loss applied" contains "$q" "loss 0.2%"
    ping_stats 10.10.0.2 40; check "RTT ~60ms (got $avg)" between "$avg" 45 85
}

test_profile_override() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile 4g --latency 100 --direction egress
    local q; q=$(tc qdisc show dev lne-$dev)
    check "explicit latency wins" contains "$q" "delay 100ms"
    check "profile rate kept" contains "$q" "rate 20Mbit"
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile transatlantic --jitter 1
    check "explicit jitter with profile latency accepted (exit $rc)" [ "$rc" -eq 0 ]
}

test_profile_list_and_errors() {
    ln --profiles
    check "lists built-in profiles" contains "$out" "satellite"
    check "shows profile values" contains "$out" "latency 600ms"
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile nope
    check "unknown profile rejected" contains "$out" "Unknown profile: nope"
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile ../../etc/passwd
    check "path in profile name rejected" contains "$out" "Unknown profile"
}

test_profile_custom() {
    mkdir -p /etc/latencyninja/profiles
    echo '{ "description": "Test link", "latency": "70", "rate": "3mbit" }' > /etc/latencyninja/profiles/lntest.json
    echo '{ "description": "Overridden", "latency": "44" }' > /etc/latencyninja/profiles/4g.json
    ln --profiles
    check "custom profile listed" contains "$out" "Test link (custom)"
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile lntest --direction egress
    check "custom profile applied" contains "$(tc qdisc show dev lne-$dev)" "delay 70ms rate 3Mbit"
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile 4g --direction egress
    check "custom file overrides built-in" contains "$(tc qdisc show dev lne-$dev)" "delay 44ms"
    rm -f /etc/latencyninja/profiles/lntest.json /etc/latencyninja/profiles/4g.json
}

test_profile_saved_as_values() {
    # Snapshots and persistence record the resolved values, so later profile edits don't change them
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile satellite --persist
    local args; args=$(tr '\n' ' ' < /etc/latencyninja/persist/$dev.args)
    check "persisted args contain resolved latency" contains "$args" "--latency 600"
    check "persisted args contain resolved rate" contains "$args" "--rate 10mbit"
    check "persisted args don't reference the profile" not_contains "$args" "--profile"
}

test_profile_and_rate_json() {
    mkdir -p "$work_dir"
    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"profile\": \"3g\", \"rate\": \"4mbit\", \"direction\": \"egress\" }" > "$work_dir/p.json"
    ln --json "$work_dir/p.json"
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "JSON rate overrides profile rate" contains "$(tc qdisc show dev lne-$dev)" "delay 200ms"
    check "JSON rate applied" contains "$(tc qdisc show dev lne-$dev)" "rate 4Mbit"
}

# ---------- tests: timed rollback ----------

test_duration_expires_to_clean() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --duration 3s
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "reports the scheduled rollback" contains "$out" "Rollback of $dev scheduled"
    check "query lists the timer" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "Scheduled rollbacks: $dev in 0m"
    ping_stats 10.10.0.2; check "rules active before expiry (got $avg)" between "$avg" 90 130
    check "rules removed after expiry" wait_for_no_rules "$dev" 15
    ping_stats 10.10.0.2; check "latency gone (got $avg)" between "$avg" 0 10
    check "query no longer lists the timer" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "Scheduled rollbacks: none"
}

test_duration_restores_previous() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --rate 2mbit --duration 3s
    ping_stats 10.10.0.2; check "temporary rules active (got $avg)" between "$avg" 18 40
    local i
    for i in $(seq 1 60); do tc qdisc show dev lne-$dev 2>/dev/null | grep -q 'delay 50ms' && break; sleep 0.25; done
    sleep 0.5
    ping_stats 10.10.0.2; check "previous rules restored after expiry (got $avg)" between "$avg" 90 130
    check "temporary rate gone" not_contains "$(tc qdisc show dev lne-$dev)" "rate"
}

test_duration_cancelled() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --duration 3s
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    sleep 5
    ping_stats 10.10.0.2; check "re-applying without --duration cancels the timer (got $avg)" between "$avg" 90 130
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100 --duration 1h
    ln --rollback --interface "$dev"
    check "rollback cancels the timer" not_contains "$(systemctl list-timers --all --no-pager)" "latencyninja-rollback-$dev"
}

test_duration_multi_interface() {
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 100 --duration 3s
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 60 --duration 1h
    check "ln0 expired" wait_for_no_rules "$dev" 15
    ping_stats 10.40.0.2; check "bond0 still shaped with its own timer (got $avg)" between "$avg" 55 80
    check "bond0 timer still listed" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "bond0 in 59m"
}

test_duration_validation() {
    local bad
    for bad in 5x 0 -5m 1.5h; do
        ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --duration "$bad"
        check "duration '$bad' rejected (exit $rc)" [ "$rc" -ne 0 ]
    done
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --duration 10m --persist
    check "--duration with --persist rejected" contains "$out" "cannot be combined with --persist"
    check "nothing applied" not_contains "$(tc qdisc show dev $dev)" "prio"
}

# ---------- tests: interface listing ----------

test_show_interfaces() {
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 10 --persist
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 10 --direction ingress
    ln --interface wg0 --dst_ip 10.30.0.2 --latency 10 --direction egress --duration 10m
    ln --show-interfaces
    check "exit code 0" [ "$rc" -eq 0 ]
    local line
    line=$(grep '^bond0 ' <<< "$out"); check "bond0: type, address, rules and persistence" contains "$line" "bond"
    check "bond0 shows IPv4 and status" contains "$line" "10.40.0.1/24         rules (both), persisted"
    line=$(grep '^wg0 ' <<< "$out")
    check "wg0: wireguard, egress rules and timed rollback" contains "$line" "wireguard"
    check "wg0 shows rollback timer" contains "$line" "rules (egress), rollback in"
    check "ln0 shows ingress rules" contains "$(grep "^$dev " <<< "$out")" "veth"
    check "ln0 status" contains "$(grep "^$dev " <<< "$out")" "rules (ingress)"
    check "bond members labelled" contains "$(grep '^lnb0 ' <<< "$out")" "bond member of bond0"
    check "ifb devices hidden" not_contains "$out" "lni-"
    check "loopback hidden" not_contains "$out" "loopback"
}

test_show_interfaces_requires_root() {
    [ -z "${SUDO_USER:-}" ] && return 77
    out=$(cd "$repo_dir" && sudo -u "$SUDO_USER" ./latencyninja --show-interfaces </dev/null 2>&1); rc=$?
    check "non-root is rejected (exit $rc)" [ "$rc" -ne 0 ]
    check "explains root is required" contains "$out" "must be run as root"
}

# ---------- tests: namespaces and containers ----------

test_netns_apply() {
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "output names the namespace" contains "$out" "Namespace: network namespace lnpeer"
    check "rollback hint includes --netns" contains "$out" "--rollback --interface lnpeer0 --netns lnpeer"
    check "ifb devices created inside the namespace" contains "$(nsenter --net=/run/netns/lnpeer ip -br link)" "lne-lnpeer0"
    check "no ifb devices on the host" not_contains "$(ip -br link)" "lnpeer0"
    ping_stats 10.10.0.2; check "traffic to the peer delayed (got $avg)" between "$avg" 90 130
    check "host ln0 untouched" not_contains "$(tc qdisc show dev $dev)" "prio"
    ln --netns lnpeer --show-interfaces
    check "show-interfaces lists the namespace's interfaces" contains "$(grep '^lnpeer0 ' <<< "$out")" "rules (both)"
    check "show-interfaces names the namespace" contains "$out" "Namespace: network namespace lnpeer"
    ln --netns lnpeer --query
    check "query lists namespace devices" contains "$out" "Device: lne-lnpeer0"
    check "query doesn't list host devices" not_contains "$out" "Device: bond0"
    ln --netns lnpeer --rollback --interface lnpeer0
    ping_stats 10.10.0.2; check "rollback inside the namespace (got $avg)" between "$avg" 0 10
}

test_netns_isolation() {
    # Same interface name on the host and in the namespace: state, rollbacks and persistence stay separate
    nsenter --net=/run/netns/lnpeer ip link add "$dev" type dummy
    nsenter --net=/run/netns/lnpeer ip addr add 10.99.0.1/24 dev "$dev"
    nsenter --net=/run/netns/lnpeer ip link set "$dev" up
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 100 --persist
    ln --netns lnpeer --interface "$dev" --dst_ip 10.99.0.2 --latency 10
    check "namespace apply exit code 0" [ "$rc" -eq 0 ]
    ln --save "$work_dir/host-snap"
    check "host snapshot has the host interface" grep -qx "\[interface $dev\]" "$work_dir/host-snap"
    check "host snapshot has the namespace interface separately" grep -qx "\[interface $dev @netns:lnpeer\]" "$work_dir/host-snap"
    ln --netns lnpeer --rollback --interface "$dev"
    check "namespace rollback doesn't unpersist the host" [ -f "/etc/latencyninja/persist/$dev.args" ]
    ping_stats 10.10.0.3; check "host rules still active (got $avg)" between "$avg" 90 130
    nsenter --net=/run/netns/lnpeer ip link delete "$dev"
}

test_netns_timed_rollback() {
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100 --duration 3s
    check "timer scheduled" contains "$out" "Rollback of lnpeer0 scheduled"
    check "timer unit is namespace specific" contains "$out" "latencyninja-rollback-ns"
    local i
    for i in $(seq 1 60); do
        nsenter --net=/run/netns/lnpeer tc qdisc show dev lnpeer0 | grep -q 'prio 1:' || break
        sleep 0.25
    done
    ping_stats 10.10.0.2; check "rules removed after expiry (got $avg)" between "$avg" 0 10
}

test_netns_snapshot() {
    mkdir -p "$work_dir"
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100
    ln --netns lnpeer --save "$work_dir/ns-snap"
    check "snapshot records the namespace" contains "$(cat "$work_dir/ns-snap")" "[namespace netns:lnpeer]"
    ln --netns lnpeer --rollback --interface lnpeer0
    ln --restore "$work_dir/ns-snap"
    check "restoring on the host is refused" contains "$out" "Restore it with the same --netns"
    ln --netns lnpeer --restore "$work_dir/ns-snap"
    check "restore in the namespace exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.10.0.2; check "namespace rules restored (got $avg)" between "$avg" 90 130
}

test_pid_target() {
    local pid; pid=$(cat /run/latencyninja-test-listener.pid)
    ln --pid "$pid" --interface lnpeer0 --dst_ip 10.10.0.1 --latency 60 --direction egress
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "output names the process" contains "$out" "Namespace: process $pid"
    ping_stats 10.10.0.2; check "traffic delayed (got $avg)" between "$avg" 55 80
    ln --pid "$pid" --rollback --interface lnpeer0
    ping_stats 10.10.0.2; check "rollback (got $avg)" between "$avg" 0 10
}

test_namespace_errors() {
    ln --netns nope --query
    check "unknown namespace rejected" contains "$out" "Network namespace not found: nope"
    ln --netns ../etc --query
    check "path in namespace name rejected" contains "$out" "Network namespace not found"
    ln --pid 999999 --query
    check "unknown PID rejected" contains "$out" "Process not found: 999999"
    ln --container lntest-nope --query
    check "unknown container rejected" contains "$out" "Container not found: lntest-nope"
    ln --netns lnpeer --pid 1 --query
    check "only one target allowed" contains "$out" "Only one of --netns, --pid or --container"
    ln --pid "$(cat /run/latencyninja-test-listener.pid)" --interface lnpeer0 --dst_ip 10.10.0.1 --latency 10 --persist
    check "--persist refused for a process" contains "$out" "isn't supported with --pid"
}

test_container_target() {
    local rt; rt=$(container_runtime)
    [ -z "$rt" ] && return 77
    "$rt" rm -f lntest &>/dev/null
    "$rt" run -d --name lntest docker.io/library/alpine:3 sleep 600 &>/dev/null || return 77
    local cip gw
    cip=$("$rt" inspect -f '{{.NetworkSettings.IPAddress}}' lntest)
    gw=$("$rt" inspect -f '{{.NetworkSettings.Gateway}}' lntest)
    ln --container lntest --interface eth0 --dst_ip "$gw" --latency 100
    check "apply exit code 0 ($rt)" [ "$rc" -eq 0 ]
    check "output names the container" contains "$out" "Namespace: $rt container lntest"
    ping_stats "$cip"; check "traffic to the container delayed (got $avg)" between "$avg" 90 130
    ln --container lntest --show-interfaces
    check "show-interfaces inside the container" contains "$(grep '^eth0 ' <<< "$out")" "rules (both)"
    check "host eth0 untouched" not_contains "$(tc qdisc show dev eth0)" "prio 1:"
    ln --container lntest --interface eth0 --dst_ip "$gw" --latency 20 --duration 3s
    local i
    for i in $(seq 1 40); do ping_stats "$cip" 3 0.2; between "$avg" 90 130 && break; sleep 0.5; done
    ping_stats "$cip"; check "timed rollback restored the previous container rules (got $avg)" between "$avg" 90 130
    ln --container lntest --rollback --interface eth0
    ping_stats "$cip"; check "rollback in the container (got $avg)" between "$avg" 0 10
    "$rt" rm -f -t 0 lntest &>/dev/null || "$rt" rm -f lntest &>/dev/null
}

# ---------- tests: feature completeness (JSON, persistence, snapshots) ----------

ns_has_rules() { nsenter --net=/run/netns/lnpeer tc qdisc show dev "${1:-lnpeer0}" 2>/dev/null | grep -q 'prio 1:'; }

test_json_every_option() {
    mkdir -p "$work_dir/jbk"; rm -f "$work_dir/jbk/"* "$work_dir/j.log"
    cat > "$work_dir/all.json" <<EOF
{ "interface": "$dev", "src_ip": "10.10.0.1", "dst_ip": ["10.10.0.2:8080", "10.10.0.3"], "direction": "egress",
  "latency": 100, "jitter": 1, "packet_loss": "0.1", "duplicate": 0.1, "corrupt": 0.1, "reorder": 1, "rate": "50mbit",
  "duration": "1h", "backup": "$work_dir/jbk", "logging": "$work_dir/j.log" }
EOF
    ln --json "$work_dir/all.json"
    check "apply exit code 0" [ "$rc" -eq 0 ]
    local q; q=$(tc qdisc show dev lne-$dev)
    local p
    for p in "delay 100ms" "loss 0.1%" "duplicate 0.1%" "corrupt 0.1%" "reorder 1%" "rate 50Mbit"; do
        check "JSON value applied: $p" contains "$q" "$p"
    done
    check "array of destinations with ports" contains "$(tc filter show dev lne-$dev)" "00001f90"
    check "duration from JSON scheduled a rollback" contains "$out" "Rollback of $dev scheduled"
    check "backup directory from JSON" [ -n "$(ls "$work_dir/jbk")" ]
    check "log file from JSON" [ -s "$work_dir/j.log" ]
    local t; t=$(tcp_rtt 10.10.0.2 8080); check "10.10.0.2:8080 delayed (got $t)" between "$t" 90 140
}

test_json_persist_and_profile() {
    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.3\", \"profile\": \"transatlantic\", \"persist\": true }" > "$work_dir/p.json"
    ln --json "$work_dir/p.json"
    check "persist from JSON" [ -f "/etc/latencyninja/persist/$dev.args" ]
    check "profile from JSON stored as values" contains "$(tr '\n' ' ' < /etc/latencyninja/persist/$dev.args)" "--latency 80"
}

test_json_namespaces() {
    echo '{ "netns": "lnpeer", "interface": "lnpeer0", "dst_ip": "10.10.0.1", "latency": 100 }' > "$work_dir/ns.json"
    ln --json "$work_dir/ns.json"
    check "netns from JSON" contains "$out" "Namespace: network namespace lnpeer"
    ping_stats 10.10.0.2; check "rules applied in the namespace (got $avg)" between "$avg" 90 130
    ln --netns lnpeer --rollback --interface lnpeer0
    echo "{ \"pid\": $(cat /run/latencyninja-test-listener.pid), \"interface\": \"lnpeer0\", \"dst_ip\": \"10.10.0.1\", \"latency\": 60, \"direction\": \"egress\" }" > "$work_dir/pid.json"
    ln --json "$work_dir/pid.json"
    check "pid from JSON" contains "$out" "Namespace: process"
    ping_stats 10.10.0.2; check "rules applied in the process namespace (got $avg)" between "$avg" 55 80
}

test_json_errors() {
    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"latncy\": 5 }" > "$work_dir/e1.json"
    ln --json "$work_dir/e1.json"; check "unknown key rejected" contains "$out" "Unknown key(s) in JSON file"
    echo "{ bad" > "$work_dir/e2.json"
    ln --json "$work_dir/e2.json"; check "invalid JSON rejected" contains "$out" "Invalid JSON file"
    echo "[1, 2]" > "$work_dir/e3.json"
    ln --json "$work_dir/e3.json"; check "non-object JSON rejected" contains "$out" "Invalid JSON file"
    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"latency\": [5] }" > "$work_dir/e4.json"
    ln --json "$work_dir/e4.json"; check "array for a scalar key rejected" contains "$out" "Invalid value type for latency"
    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"latency\": 5, \"persist\": \"maybe\" }" > "$work_dir/e5.json"
    ln --json "$work_dir/e5.json"; check "invalid persist value rejected" contains "$out" "Invalid value for persist"
    echo '{ "netns": "lnpeer", "pid": 1, "interface": "lnpeer0" }' > "$work_dir/e6.json"
    ln --json "$work_dir/e6.json"; check "two targets rejected" contains "$out" "Only one of container, netns or pid"
    echo '{ "netns": "lnpeer", "interface": "lnpeer0", "dst_ip": "10.10.0.1", "latency": 5 }' > "$work_dir/e7.json"
    ln --pid 1 --json "$work_dir/e7.json"; check "target on command line and in JSON rejected" contains "$out" "both on the command line and in the JSON file"
    ln --json /nonexistent.json; check "missing file rejected" contains "$out" "JSON file not found"
    check "nothing applied" not_contains "$(tc qdisc show dev $dev)" "prio"
}

test_profile_unknown_key() {
    mkdir -p /etc/latencyninja/profiles
    echo '{ "description": "Typo", "latncy": "70" }' > /etc/latencyninja/profiles/lntypo.json
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile lntypo
    check "unknown profile key rejected" contains "$out" "Unknown key(s) in profile"
    rm -f /etc/latencyninja/profiles/lntypo.json
}

test_persist_netns() {
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100 --persist
    check "apply exit code 0" [ "$rc" -eq 0 ]
    check "persisted in the namespace" [ -f /etc/latencyninja/persist/netns/lnpeer/lnpeer0.args ]
    check "watcher running" systemctl is-active -q latencyninja-namespaces.service
    check "query lists the namespace interface" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "lnpeer0@netns:lnpeer"
    check "show-interfaces marks it persisted" contains "$(cd "$repo_dir" && ./latencyninja --netns lnpeer --show-interfaces </dev/null | grep '^lnpeer0 ')" "persisted"

    # Rules removed in the same namespace (e.g. --restore) are not re-applied
    ln --netns lnpeer --rollback --interface lnpeer0 --keep-persist
    sleep 7
    check "not re-applied in the same namespace" not ns_has_rules

    # A re-created interface gets its rules back
    bash "$tests_dir/netns_setup.sh" veth-recreate
    local i
    for i in $(seq 1 60); do ns_has_rules && break; sleep 0.25; done
    check "re-applied after the interface was re-created" ns_has_rules
    sleep 0.5
    ping_stats 10.10.0.2; check "re-applied rules effective (got $avg)" between "$avg" 90 130

    ln --netns lnpeer --rollback --interface lnpeer0
    check "rollback removes namespace persistence" [ ! -f /etc/latencyninja/persist/netns/lnpeer/lnpeer0.args ]
    check "watcher stopped when nothing is persisted" not systemctl is-active -q latencyninja-namespaces.service
}

test_persist_container() {
    local rt; rt=$(container_runtime)
    [ -z "$rt" ] && return 77
    "$rt" rm -f lntest &>/dev/null
    "$rt" run -d --name lntest docker.io/library/alpine:3 sleep 600 &>/dev/null || return 77
    local gw cip
    gw=$("$rt" inspect -f '{{.NetworkSettings.Gateway}}' lntest)
    ln --container lntest --interface eth0 --dst_ip "$gw" --latency 100 --persist
    check "persisted by container name" [ -f /etc/latencyninja/persist/container/lntest/eth0.args ]
    "$rt" restart -t 0 lntest &>/dev/null
    cip=$("$rt" inspect -f '{{.NetworkSettings.IPAddress}}' lntest)
    local i
    for i in $(seq 1 30); do
        (cd "$repo_dir" && ./latencyninja --container lntest --show-interfaces </dev/null 2>/dev/null) | grep -q 'rules (both)' && break
        sleep 0.5
    done
    sleep 0.5
    ping_stats "$cip"; check "rules re-applied after the container restarted (got $avg)" between "$avg" 90 130
    ln --container lntest --rollback --interface eth0
    check "rollback removes container persistence" [ ! -f /etc/latencyninja/persist/container/lntest/eth0.args ]
    "$rt" rm -f -t 0 lntest &>/dev/null || "$rt" rm -f lntest &>/dev/null
}

test_snapshot_all_namespaces() {
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 60
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100
    ln --save "$work_dir/everything.snap"
    check "summary lists the namespace interface" contains "$out" "lnpeer0@netns:lnpeer"
    ln --rollback --interface bond0
    ln --netns lnpeer --rollback --interface lnpeer0
    ln --restore "$work_dir/everything.snap" --interface bond0
    check "scoped restore leaves namespaces alone" not ns_has_rules
    ln --restore "$work_dir/everything.snap"
    check "restore exit code 0" [ "$rc" -eq 0 ]
    ping_stats 10.40.0.2; check "host rules restored (got $avg)" between "$avg" 55 80
    ping_stats 10.10.0.2; check "namespace rules restored (got $avg)" between "$avg" 90 130
    ln --save "$work_dir/empty.snap"
    ln --rollback --interface bond0
    ln --netns lnpeer --rollback --interface lnpeer0
    ln --save "$work_dir/empty.snap"
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 60
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100
    ln --restore "$work_dir/empty.snap"
    check "clean host snapshot also rolls back namespaces" not ns_has_rules
}

test_namespace_aliases() {
    # The same namespace targeted two ways shares its state; a host process is the host
    local pid; pid=$(cat /run/latencyninja-test-listener.pid)
    ln --pid "$pid" --interface lnpeer0 --dst_ip 10.10.0.1 --latency 60
    ln --netns lnpeer --rollback --interface lnpeer0
    ln --save "$work_dir/alias.snap"
    check "rollback through another target clears the state" not grep -q 'lnpeer0 @' "$work_dir/alias.snap"
    ln --pid 1 --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    check "a host process is treated as the host" contains "$out" "uses the host network namespace"
    check "rules applied on the host" contains "$(tc qdisc show dev lne-$dev 2>/dev/null)" "delay 50ms"
    check "no namespace hint for the host" not_contains "$out" "--pid 1"
}

# ---------- tests: input validation and normalization ----------

test_validation_normalization() {
    local bad
    for bad in abc50 1.2.3 1e3 "5 0" 5%; do
        ln --interface "$dev" --dst_ip 10.10.0.2 --latency "$bad"
        check "latency '$bad' rejected" contains "$out" "positive numeric value"
    done
    for bad in 101 150 1000; do
        ln --interface "$dev" --dst_ip 10.10.0.2 --packet_loss "$bad"
        check "packet_loss '$bad' rejected" contains "$out" "can't be more than 100"
    done
    for bad in 999.1.1.1 10.0.0.256 10.0.0.1/33 10.0.0.1:65536 10.0.0.1: 10.0.0.1:x; do
        ln --interface "$dev" --dst_ip "$bad" --latency 10
        check "dst_ip '$bad' rejected (exit $rc)" [ "$rc" -ne 0 ]
    done
    check "nothing applied by rejected values" not_contains "$(tc qdisc show dev $dev)" "prio"

    # A port is never evaluated by bash
    rm -f "$work_dir/pwned"; mkdir -p "$work_dir"
    ln --interface "$dev" --dst_ip "10.10.0.2:a[\$(touch $work_dir/pwned)]" --latency 10
    check "non-numeric port rejected" contains "$out" "not in the range"
    check "port was not evaluated" [ ! -e "$work_dir/pwned" ]

    # Units, spaces, case and leading zeros are cleaned up; the result is what is applied and stored
    ln --interface "$dev" --dst_ip " 010.010.000.002 , 10.10.0.2 " --latency " 100ms " --packet_loss "0.5%" --direction EGRESS --rate " 50Mbit "
    check "cleaned values apply (exit $rc)" [ "$rc" -eq 0 ]
    local q; q=$(tc qdisc show dev lne-$dev)
    check "latency 100ms" contains "$q" "delay 100ms"
    check "packet loss 0.5%" contains "$q" "loss 0.5%"
    check "rate applied" contains "$q" "rate 50Mbit"
    ln --save "$work_dir/norm.snap"
    check "leading zeros removed and duplicates dropped" grep -qx -- '10.10.0.2' "$work_dir/norm.snap"
    check "no duplicate entry" not grep -q -- '10.10.0.2,' "$work_dir/norm.snap"
    check "values stored normalized" grep -qx -- '0.5' "$work_dir/norm.snap"
    ln --rollback --interface "$dev"

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --jitter 50
    check "jitter larger than latency warns" contains "$out" "Warning: the jitter (50 ms) is larger than the latency (20 ms)"
    check "and still applies" contains "$(tc qdisc show dev lne-$dev)" "delay 10ms"
    ln --interface "$dev" --dst_ip 10.10.0.2 --reorder 5 --packet_loss 1
    check "reorder without latency is rejected (tc refuses it)" contains "$out" "Reorder can only be used with latency"

    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"packet_loss\": 150 }" > "$work_dir/v1.json"
    ln --json "$work_dir/v1.json"; check "JSON values are validated too" contains "$out" "can't be more than 100"
    mkdir -p /etc/latencyninja/profiles
    echo '{ "description": "Bad", "latency": "0" }' > /etc/latencyninja/profiles/lnbad.json
    ln --interface "$dev" --dst_ip 10.10.0.2 --profile lnbad
    check "profile values are validated too" contains "$out" "positive numeric value"
    rm -f /etc/latencyninja/profiles/lnbad.json
}

# ---------- tests: SSH lockout guard ----------

# Run latencyninja as if the command was started from an SSH session of 10.10.0.2 (reachable through ln0)
ln_ssh() {
    out=$(cd "$repo_dir" && SSH_CONNECTION="10.10.0.2 40000 10.10.0.1 22" ./latencyninja "$@" </dev/null 2>&1)
    rc=$?
}

# Run latencyninja with a tc that fails once when it is asked to set up netem, to test failed applies
ln_failing_tc() {
    mkdir -p "$work_dir/failtc"
    cat > "$work_dir/failtc/tc" <<EOF
#!/bin/sh
case "\$*" in
    *netem*) if [ -e "$work_dir/failtc/once" ]; then rm -f "$work_dir/failtc/once"; echo "injected tc failure" >&2; exit 1; fi ;;
esac
exec "$(command -v tc)" "\$@"
EOF
    chmod +x "$work_dir/failtc/tc"
    touch "$work_dir/failtc/once"
    out=$(cd "$repo_dir" && PATH="$work_dir/failtc:$PATH" ./latencyninja "$@" </dev/null 2>&1)
    rc=$?
}

test_failed_apply_undone() {
    ln_failing_tc --interface "$dev" --dst_ip 10.10.0.2 --latency 10
    check "a failed apply returns non-zero (exit $rc)" [ "$rc" -ne 0 ]
    check "says the rules were put back" contains "$out" "restoring the previous rules"
    check "no prio qdisc left" not_contains "$(tc qdisc show dev $dev)" "prio"
    check "no ingress qdisc left" not_contains "$(tc qdisc show dev $dev)" "ingress"
    check "no ifb devices left" not_contains "$(ip -o link show)" "-$dev:"
    # The rules from before the failed apply come back
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40
    ln_failing_tc --interface "$dev" --dst_ip 10.10.0.2 --latency 80
    check "failed re-apply returns non-zero" [ "$rc" -ne 0 ]
    check "previous rules are back" contains "$(tc qdisc show dev lne-$dev)" "delay 20ms"
    check "and not the new ones" not_contains "$(tc qdisc show dev lne-$dev)" "delay 40ms"
    ln --rollback --interface "$dev"
    ln --check
    check "--check finds no leftover ifb device" not_contains "$out" "ifb device"
    check "--check finds no leftover redirect" not_contains "$out" "redirect"
}

test_failed_apply_timer_kept() {
    # A failed apply must not cancel the pending timed rollback of the rules that stay
    ln --interface "$dev" --dst_ip 10.10.0.3 --latency 40 --duration 10m
    check "timed rollback scheduled" contains "$(systemctl list-timers --no-legend 'latencyninja-rollback-*')" "latencyninja-rollback-$dev"
    ln_failing_tc --interface "$dev" --dst_ip 10.10.0.3 --latency 80
    check "failed apply returns non-zero" [ "$rc" -ne 0 ]
    ln --query
    check "the timed rollback is still scheduled" not_contains "$out" "Scheduled rollbacks: none"
}

test_bad_logging_path() {
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --duration 5m --logging /nonexistent/x.log
    check "a bad log path is rejected (exit $rc)" [ "$rc" -ne 0 ]
    check "says why" contains "$out" "Log directory does not exist"
    check "nothing was applied" not_contains "$(tc qdisc show dev $dev)" "prio"
    check "no rollback timer" not_contains "$(systemctl list-timers --all --no-legend 'latencyninja-rollback-*')" "latencyninja-rollback-$dev"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --logging /nonexistent/x.log
    check "--dry-run checks the log path too" contains "$out" "Log directory does not exist"
}

test_options_without_value() {
    local opt
    for opt in --json --backup --logging; do
        out=$(cd "$repo_dir" && timeout 20 ./latencyninja --interface "$dev" --dst_ip 10.10.0.2 --latency 10 "$opt" </dev/null 2>&1); rc=$?
        check "$opt without a value is an error, not a hang (exit $rc)" [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]
        check "$opt explains what is missing" contains "$out" "requires an argument"
    done
}

test_value_limits() {
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 274878 --direction egress
    check "latency above the tc limit is rejected in one direction" contains "$out" "can't be more than 274877 ms in one direction"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 274877 --direction egress
    check "latency at the tc limit is accepted (exit $rc)" [ "$rc" -eq 0 ]
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 549754 --jitter 100
    check "with both directions the limit doubles (exit $rc)" [ "$rc" -eq 0 ]
    check "and each direction gets half" contains "$out" "netem delay 274877ms 50ms"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 549755
    check "above that is rejected" contains "$out" "can't be more than 549754 ms"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --jitter 300000 --direction egress
    check "jitter is limited too" contains "$out" "Latency and jitter can't be more than"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 123.456
    check "halving keeps the precision" contains "$out" "netem delay 61.728ms"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --rate 99999999999999999999mbit
    check "absurd rates are rejected" contains "$out" "The rate must be between"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --rate 1bit
    check "rates below 1 byte per second are rejected" contains "$out" "The rate must be between"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --rate 1bps
    check "1bps is accepted (exit $rc)" [ "$rc" -eq 0 ]
}

test_foreign_qdiscs() {
    tc qdisc replace dev "$dev" root handle 5: htb default 1
    ln --rollback --interface "$dev"
    check "--rollback leaves a qdisc it didn't set up" contains "$(tc qdisc show dev $dev)" "htb 5:"

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10
    check "applying warns that the qdisc is replaced" contains "$out" "has a htb root qdisc, which is replaced"
    check "and applies (exit $rc)" [ "$rc" -eq 0 ]
    ln --rollback --interface "$dev"
    check "rollback removes ours" not_contains "$(tc qdisc show dev $dev)" "prio"

    tc qdisc replace dev "$dev" root noqueue 2>/dev/null
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10
    check "default qdiscs are replaced without a warning" not_contains "$out" "Warning"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 20
    check "re-applying our own rules does not warn" not_contains "$out" "Warning"
}

test_dry_run() {
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2:80 --latency 40 --jitter 5 --packet_loss 1
    check "dry run succeeds (exit $rc)" [ "$rc" -eq 0 ]
    check "shows the netem command" contains "$out" "tc qdisc add dev lne-$dev parent 1:1 handle 20:0 netem delay 20ms 2.5ms loss 1%"
    check "shows the ingress redirect" contains "$out" "redirect dev lni-$dev"
    check "shows the filter with the port" contains "$out" "match ip dport 80 0xffff"
    check "says nothing was changed" contains "$out" "nothing was changed"
    check "gives the command to apply" contains "$out" "To apply, run: sudo ./latencyninja --interface $dev --dst_ip 10.10.0.2:80"
    check "no rules" not_contains "$(tc qdisc show dev $dev)" "prio"
    check "no ifb devices" not_contains "$(ip -o link show)" "-$dev:"

    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --direction egress --logging "$work_dir/dry.log" --backup "$work_dir"
    check "egress only creates the egress device" contains "$out" "ip link add lne-$dev type ifb"
    check "egress only doesn't create the ingress device" not_contains "$out" "ip link add lni-$dev"
    check "no log file" not test -e "$work_dir/dry.log"
    check "no backup file" not_contains "$(ls "$work_dir" 2>/dev/null)" "latencyninja_tc_backup"

    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency abc
    check "invalid values still fail (exit $rc)" [ "$rc" -ne 0 ]
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --duration 10m --persist --latency 20
    check "options that can't work together are caught" contains "$out" "--duration option cannot be combined with --persist"

    ln --dry-run --rollback --interface "$dev"
    check "can't be combined with --rollback" contains "$out" "only previews applying rules"
    ln --dry-run --check
    check "can't be combined with --check" contains "$out" "only previews applying rules"

    ln_ssh --dry-run --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 50
    check "the SSH guard applies to dry runs (exit $rc)" contains "$out" "SSH session"

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 80
    check "existing rules are untouched by a dry run" contains "$(tc qdisc show dev lne-$dev)" "delay 20ms"
}

test_ssh_guard() {
    ln_ssh --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 50
    check "rules matching the SSH client refused (exit $rc)" [ "$rc" -ne 0 ]
    check "explains the lockout" contains "$out" "would also affect your SSH session from 10.10.0.2"
    check "offers the ways out" contains "$out" "--allow-ssh"
    check "nothing applied" not_contains "$(tc qdisc show dev $dev)" "prio"

    ln_ssh --interface "$dev" --dst_ip 10.10.0.0/24 --latency 20
    check "a network containing the client is refused too" contains "$out" "SSH session"

    ln_ssh --interface "$dev" --dst_ip 10.10.0.3 --packet_loss 50
    check "rules for another host apply (exit $rc)" [ "$rc" -eq 0 ]
    ln --rollback --interface "$dev"

    ln_ssh --interface "$dev" --dst_ip 10.10.0.2:80 --latency 20
    check "a port that is not the session's applies (exit $rc)" [ "$rc" -eq 0 ]
    ln --rollback --interface "$dev"

    ln_ssh --interface "$dev" --dst_ip 10.10.0.2:22 --latency 20
    check "the SSH port is refused" contains "$out" "SSH session"

    ln_ssh --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 50 --allow-ssh
    check "--allow-ssh applies the rules (exit $rc)" [ "$rc" -eq 0 ]
    check "rules are in place" contains "$(tc qdisc show dev lne-$dev)" "loss 50%"
    ln --rollback --interface "$dev"

    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"packet_loss\": 50, \"allow_ssh\": true }" > "$work_dir/ssh.json"
    ln_ssh --json "$work_dir/ssh.json"
    check "allow_ssh in a JSON file (exit $rc)" [ "$rc" -eq 0 ]
    ln --rollback --interface "$dev"
    echo "{ \"interface\": \"$dev\", \"dst_ip\": \"10.10.0.2\", \"packet_loss\": 50, \"allow_ssh\": \"maybe\" }" > "$work_dir/ssh2.json"
    ln --json "$work_dir/ssh2.json"
    check "invalid allow_ssh rejected" contains "$out" "Invalid value for allow_ssh"

    # Restoring brings back rules that were applied before, so it isn't blocked
    ln --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 50 --allow-ssh
    ln --save "$work_dir/ssh.snap"
    ln --rollback --interface "$dev"
    out=$(cd "$repo_dir" && SSH_CONNECTION="10.10.0.2 40000 10.10.0.1 22" ./latencyninja --restore "$work_dir/ssh.snap" </dev/null 2>&1); rc=$?
    check "restore is not blocked (exit $rc)" [ "$rc" -eq 0 ]
    check "restored rules in place" contains "$(tc qdisc show dev lne-$dev)" "loss 50%"
    ln --rollback --interface "$dev"

    # A session that doesn't go through the shaped interface is not affected
    out=$(cd "$repo_dir" && SSH_CONNECTION="10.40.0.2 40000 10.10.0.1 22" ./latencyninja --interface "$dev" --dst_ip 10.40.0.2 --packet_loss 50 </dev/null 2>&1); rc=$?
    check "session over another interface (exit $rc)" [ "$rc" -eq 0 ]
    ln --rollback --interface "$dev"
}

test_ssh_guard_duration() {
    command -v systemd-run &>/dev/null && [ -d /run/systemd/system ] || return 77
    ln_ssh --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 50 --duration 1h
    check "--duration makes it safe (exit $rc)" [ "$rc" -eq 0 ]
    check "warns about the session" contains "$out" "affect your SSH session from 10.10.0.2"
    check "rollback scheduled" contains "$out" "Rollback of $dev scheduled"
    check "rules in place" contains "$(tc qdisc show dev lne-$dev)" "loss 50%"
}

# ---------- tests: --check and --clean ----------

test_check_clean() {
    modprobe ifb 2>/dev/null
    local fixture_state="/run/latencyninja"

    # Orphaned ifb device
    ip link add lne-orphan0 type ifb
    ln --check
    check "--check exits 1 with a problem" [ "$rc" -eq 1 ]
    check "orphaned ifb device reported" contains "$out" "ifb device lne-orphan0 is not used by any interface"
    check "--check changes nothing" ip link show lne-orphan0
    ln --clean
    check "--clean without a terminal needs --yes" contains "$out" "use --yes"
    check "and removes nothing" ip link show lne-orphan0
    ln --clean --yes
    check "--clean --yes exit code 0 or leftovers only (exit $rc)" [ "$rc" -le 1 ]
    check "orphaned ifb device removed" not ip link show lne-orphan0

    # Rules that are applied are not touched, and are not reported
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 100
    ln --check
    check "active rules are not reported" not_contains "$out" "Rules on $dev"
    check "their ifb devices are not reported" not_contains "$out" "ifb device lne-$dev"
    ln --clean --yes
    check "active rules survive --clean" contains "$(tc qdisc show dev lne-$dev)" "delay 50ms"
    ping_stats 10.10.0.2; check "and still delay traffic (got $avg)" between "$avg" 90 130

    # Rules redirecting to an ifb device that is gone
    ip link delete lne-$dev
    ln --check
    check "dangling redirect reported" contains "$out" "Rules on $dev redirect egress traffic to lne-$dev, which no longer exists"
    ln --clean --yes
    check "interface rules removed" not_contains "$(tc qdisc show dev $dev)" "prio"
    ln --check
    check "nothing about $dev left" not_contains "$out" "Rules on $dev"

    # Stale saved rules
    mkdir -p "$fixture_state"
    printf -- '--interface\nlnghost0\n--latency\n10\n' > "$fixture_state/lnghost0.args"
    ln --check
    check "saved rules of a missing interface reported" contains "$out" "Saved rules of lnghost0: the interface no longer exists"
    ln --clean --yes
    check "stale saved rules removed" [ ! -e "$fixture_state/lnghost0.args" ]

    # Persisted rules that cannot be applied
    mkdir -p /etc/latencyninja/persist && chmod 700 /etc/latencyninja/persist
    printf -- '--interface\nlnghost1\n--packet_loss\n500\n' > /etc/latencyninja/persist/lnghost1.args
    printf -- '--interface\nlnghost2\n--latency\n30\n' > /etc/latencyninja/persist/lnghost2.args
    ln --check
    check "invalid persisted rules reported" contains "$out" "Persisted rules for lnghost1 cannot be applied: Invalid packet_loss format"
    check "valid persisted rules for a missing interface are information" contains "$out" "Persisted rules for lnghost2: the interface doesn't exist now"
    check "and not counted as fixable" not_contains "$out" "[clean]  Persisted rules for lnghost2"
    ln --clean --yes
    check "invalid persisted rules removed" [ ! -e /etc/latencyninja/persist/lnghost1.args ]
    check "valid persisted rules kept" [ -e /etc/latencyninja/persist/lnghost2.args ]
    rm -f /etc/latencyninja/persist/lnghost2.args

    # Old backups, except those a pending timed rollback needs
    mkdir -p "$work_dir/bk"; rm -f "$work_dir/bk/"*
    touch -d "60 days ago" "$work_dir/bk/latencyninja_tc_backup_old"
    touch "$work_dir/bk/latencyninja_tc_backup_new"
    ln --check --backup "$work_dir/bk"
    check "old backup reported" contains "$out" "1 backup file(s)"
    ln --clean --yes --backup "$work_dir/bk"
    check "old backup removed" [ ! -e "$work_dir/bk/latencyninja_tc_backup_old" ]
    check "recent backup kept" [ -e "$work_dir/bk/latencyninja_tc_backup_new" ]

    # Invalid custom profiles are reported but never changed
    mkdir -p /etc/latencyninja/profiles
    echo '{ "description": "Typo", "latncy": "70" }' > /etc/latencyninja/profiles/lncheck.json
    ln --check
    check "invalid profile reported" contains "$out" "lncheck.json is not valid: unknown key(s): latncy"
    ln --clean --yes
    check "invalid profile left alone" [ -e /etc/latencyninja/profiles/lncheck.json ]
    check "--clean reports what is left" contains "$out" "need attention"
    rm -f /etc/latencyninja/profiles/lncheck.json

    ln --check --latency 10
    check "--check can't be combined with rules" contains "$out" "can't be combined"
}

test_check_clean_namespace() {
    modprobe ifb 2>/dev/null
    ip -n lnpeer link add lne-orphan1 type ifb
    ip link add lne-orphan2 type ifb
    ln --netns lnpeer --check
    check "the namespace is named" contains "$out" "Checking network namespace lnpeer"
    check "orphan in the namespace reported" contains "$out" "ifb device lne-orphan1"
    check "orphan on the host not reported" not_contains "$out" "lne-orphan2"
    ln --netns lnpeer --clean --yes
    check "orphan in the namespace removed" not ip -n lnpeer link show lne-orphan1
    check "orphan on the host untouched" ip link show lne-orphan2
    ip link delete lne-orphan2
}


# ---------- tests: 1.29 (JSON output, --stats, audit log, --confirm-within, --probe, --run-in) ----------

# Run latencyninja with a PATH that doesn't have the given commands, to check what is (not) required
declare -A without_dirs=()
ln_without() {
    local missing="$1" f
    shift
    if [ -z "${without_dirs[$missing]}" ]; then
        without_dirs[$missing]=$(mktemp -d "/tmp/lnpath-without-$missing.XXXXXX")
        for f in /usr/bin/* /usr/sbin/*; do
            [ -x "$f" ] && [ "${f##*/}" != "$missing" ] && command ln -sf "$f" "${without_dirs[$missing]}/${f##*/}"
        done
    fi
    out=$(cd "$repo_dir" && PATH="${without_dirs[$missing]}" "$(command -v timeout)" 60 "$(command -v bash)" ./latencyninja "$@" </dev/null 2>&1)
    rc=$?
}

# Remove the directories ln_without built
ln_without_cleanup() {
    rm -rf "${without_dirs[@]}"
    without_dirs=()
}

test_json_output() {
    local json
    ln --interface "$dev" --dst_ip 10.10.0.2:80~443 --latency 40 --jitter 4 --packet_loss 1 --rate 5mbit --duration 10m
    json=$(cd "$repo_dir" && ./latencyninja --query --format json </dev/null)
    check "--query --format json is valid JSON" jq -e . <<< "$json" >/dev/null
    check "the device with rules has its filters" [ "$(jq -r '[.devices[] | select(.device == "lni-'"$dev"'") | .filters[]] | length' <<< "$json")" -ge 1 ]
    check "filters have addresses and ports" [ "$(jq -r '[.devices[].filters[] | select(.dst_ip == "10.10.0.2/32" and .dst_port == 80)] | length' <<< "$json")" -ge 1 ]
    check "netem values are parsed" [ "$(jq -r '[.devices[].netem[] | select(.delay == "20ms" and .jitter == "2ms" and .loss == "1%" and .rate == "5Mbit")] | length' <<< "$json")" -ge 1 ]
    check "the timed rollback is listed" [ "$(jq -r '.scheduled_rollbacks[0].interface' <<< "$json")" = "$dev" ]
    check "with the seconds left" between "$(jq -r '.scheduled_rollbacks[0].seconds_left' <<< "$json")" 500 600
    check "not awaiting confirmation" [ "$(jq -r '.scheduled_rollbacks[0].awaiting_confirmation' <<< "$json")" = "false" ]
    check "persisted interfaces is an array" [ "$(jq -r '.persisted_interfaces | type' <<< "$json")" = "array" ]
    check "text output is unchanged" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "Scheduled rollbacks: $dev in"
    check "the format can come after --query" [ "$(cd "$repo_dir" && ./latencyninja --format json --query </dev/null | jq -r '.devices | length')" -ge 1 ]

    json=$(cd "$repo_dir" && ./latencyninja --show-interfaces --format json </dev/null)
    check "--show-interfaces --format json is valid JSON" jq -e . <<< "$json" >/dev/null
    check "reports the rules of the interface" [ "$(jq -r '.interfaces[] | select(.name == "'"$dev"'") | .latencyninja.rules' <<< "$json")" = "both" ]
    check "reports its address" [ "$(jq -r '.interfaces[] | select(.name == "'"$dev"'") | .ipv4' <<< "$json")" = "10.10.0.1/24" ]
    check "reports the rollback time left" between "$(jq -r '.interfaces[] | select(.name == "'"$dev"'") | .latencyninja.rollback_seconds_left' <<< "$json")" 500 600
    check "interfaces without rules say none" [ "$(jq -r '.interfaces[] | select(.name == "bond0") | .latencyninja.rules' <<< "$json")" = "none" ]
    check "ifb devices are hidden" [ "$(jq -r '[.interfaces[] | select(.kind == "ifb")] | length' <<< "$json")" = "0" ]

    ln --query --format xml
    check "an unknown format is refused (exit $rc)" contains "$out" "Invalid format: xml"
    ln --format
    check "--format needs a value" contains "$out" "The --format option requires an argument."

    ln --netns lnpeer --show-interfaces --format json
    check "works in a namespace" [ "$(jq -r '.namespace' <<< "$out")" = "network namespace lnpeer" ]
}

test_stats() {
    ln --stats
    check "no rules: says so (exit $rc)" contains "$out" "No Latency Ninja rules"
    ln --stats --format json
    check "no rules: empty JSON list" [ "$(jq -r '.stats | length' <<< "$out")" = "0" ]

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --packet_loss 30
    ping -c 30 -i 0.02 -W 1 10.10.0.2 >/dev/null 2>&1
    ln --stats
    check "--stats succeeds" [ "$rc" -eq 0 ]
    check "lists both directions" contains "$out" "$dev          ingress"
    check "and egress" contains "$out" "$dev          egress"
    ln --stats --format json
    check "JSON is valid" jq -e . <<< "$out" >/dev/null
    check "egress packets are counted" [ "$(jq -r '.stats[] | select(.direction == "egress") | .packets' <<< "$out")" -gt 0 ]
    check "ingress bytes are counted" [ "$(jq -r '.stats[] | select(.direction == "ingress") | .bytes' <<< "$out")" -gt 0 ]
    check "packet loss shows as drops" [ "$(jq -r '[.stats[].drops] | add' <<< "$out")" -gt 0 ]
    ln --stats --interface bond0
    check "scoped to an interface without rules" contains "$out" "No Latency Ninja rules on bond0"
    ln --stats --interface nosuchif
    check "unknown interface is refused" contains "$out" "Invalid interface: nosuchif"
    ln --netns lnpeer --stats
    check "namespace: nothing there" contains "$out" "No Latency Ninja rules"
}

test_audit_log() {
    local audit="$work_dir/audit.log" last
    rm -f "$audit"; mkdir -p "$work_dir"
    SUDO_USER=alice ln --interface "$dev" --dst_ip 10.10.0.2:80 --latency 40 --profile 4g --audit-log "$audit"
    check "apply succeeds" [ "$rc" -eq 0 ]
    check "an entry is written" [ "$(wc -l < "$audit")" -eq 1 ]
    last=$(tail -1 "$audit")
    check "every line is JSON" jq -e . <<< "$last" >/dev/null
    check "event is apply" [ "$(jq -r .event <<< "$last")" = "apply" ]
    check "records who ran it (the user behind sudo)" [ "$(jq -r .actor <<< "$last")" = "alice" ]
    check "records the interface" [ "$(jq -r .interface <<< "$last")" = "$dev" ]
    check "records the destination with its port" [ "$(jq -r .dst_ip <<< "$last")" = "10.10.0.2:80" ]
    check "records the values" [ "$(jq -r .latency <<< "$last")" = "40" ]
    check "records the profile" [ "$(jq -r .profile <<< "$last")" = "4g" ]
    check "records the command line" contains "$(jq -r .command <<< "$last")" "--audit-log $audit"
    check "records a UTC timestamp" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<< "$(jq -r .ts <<< "$last")"
    check "records the host" [ -n "$(jq -r .host <<< "$last")" ]
    check "records the version" [ "$(jq -r .version <<< "$last")" = "$(cat "$repo_dir/version.txt")" ]
    check "records the backup file" [ -f "$(jq -r .backup <<< "$last")" ]
    check "empty values are left out" [ "$(jq -r 'has("corrupt")' <<< "$last")" = "false" ]

    SSH_CONNECTION="10.0.0.9 5555 10.0.0.1 22" ln --interface "$dev" --rollback --audit-log "$audit"
    last=$(tail -1 "$audit")
    check "rollback is recorded" [ "$(jq -r .event <<< "$last")" = "rollback" ]
    check "with the SSH client address as the source" [ "$(jq -r .source <<< "$last")" = "10.0.0.9" ]

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --duration 2s --audit-log "$audit"
    check "the timer rolls back" wait_for_no_rules "$dev" 15
    sleep 1
    last=$(tail -1 "$audit")
    check "the timed rollback is recorded" [ "$(jq -r .event <<< "$last")" = "timed_rollback" ]
    check "as done by the timer" [ "$(jq -r .actor <<< "$last")" = "systemd timer" ]

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --duration 1h --audit-log "$audit"
    check "duration is recorded" [ "$(tail -1 "$audit" | jq -r .duration)" = "1h" ]
    ln --interface "$dev" --rollback --audit-log "$audit"
    ln --netns lnpeer --interface "$dev" --rollback
    local before; before=$(wc -l < "$audit")
    ln --save "$work_dir/audit.snap" --audit-log "$audit"
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --audit-log "$audit"
    check "saving and dry runs change nothing and are not recorded" [ "$(wc -l < "$audit")" -eq "$before" ]

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --audit-log "$work_dir/audit-ns.log" --logging "$work_dir/ln.log"
    ln --restore "$work_dir/audit.snap" --audit-log "$audit"
    check "restore is recorded" [ "$(tail -1 "$audit" | jq -r .event)" = "restore" ]

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --audit-log /nonexistent/dir/audit.log
    check "a bad audit log path is refused before applying (exit $rc)" contains "$out" "Audit log directory does not exist"
    check "and nothing is applied" not_contains "$(tc qdisc show dev $dev)" "prio"
    touch "$work_dir/ro.log"; chmod 444 "$work_dir/ro.log"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --audit-log "$work_dir/ro.log"
    [ "$(id -u)" -eq 0 ] || check "a read-only audit log is refused" contains "$out" "Audit log is not writable"

    ln --netns lnpeer --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --audit-log "$audit" 2>/dev/null
    rm -f "$audit"
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 10 --audit-log "$audit"
    [ -f "$audit" ] && check "a namespace is recorded" [ "$(tail -1 "$audit" | jq -r .namespace)" = "network namespace lnpeer" ]
}

test_confirm_within() {
    local audit="$work_dir/confirm-audit.log"
    rm -f "$audit"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 90s --audit-log "$audit"
    check "apply succeeds (exit $rc)" [ "$rc" -eq 0 ]
    check "shows the confirmation countdown" contains "$out" "Confirm within: 90s"
    check "tells how to keep the rules" contains "$out" "To keep the rules, run: sudo ./latencyninja --confirm --interface $dev"
    check "query shows it is unconfirmed" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "Scheduled rollbacks: $dev in 1m"
    check "query says so" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "(unconfirmed)"
    check "--show-interfaces says so" contains "$(cd "$repo_dir" && ./latencyninja --show-interfaces </dev/null)" "(unconfirmed)"
    check "JSON says so" [ "$(cd "$repo_dir" && ./latencyninja --query --format json </dev/null | jq -r '.scheduled_rollbacks[0].awaiting_confirmation')" = "true" ]
    check "the log records the confirmation window" contains "$(cat /var/log/latencyninja/latencyninja.log)" "Confirm within: 90s"
    check "the audit log records it" [ "$(tail -1 "$audit" | jq -r .confirm_within)" = "90s" ]
    ping_stats 10.10.0.2; check "rules are active (got $avg)" between "$avg" 40 70

    ln --confirm --interface "$dev" --audit-log "$audit"
    check "--confirm succeeds (exit $rc)" [ "$rc" -eq 0 ]
    check "says the rules stay" contains "$out" "the rules on $dev stay in place"
    check "the timer is gone" contains "$(cd "$repo_dir" && ./latencyninja --query </dev/null)" "Scheduled rollbacks: none"
    check "the confirmation is recorded" [ "$(tail -1 "$audit" | jq -r .event)" = "confirm" ]
    ping_stats 10.10.0.2; check "rules are still active (got $avg)" between "$avg" 40 70
    ln --confirm --interface "$dev"
    check "confirming twice is refused (exit $rc)" contains "$out" "Nothing to confirm"
    ln --check
    check "--check finds no state left over" not_contains "$out" "$dev"

    # Without a confirmation the rules are rolled back by themselves (to what was there before: nothing)
    ln --interface "$dev" --rollback
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 3s
    check "rules roll back when not confirmed" wait_for_no_rules "$dev" 15
    ping_stats 10.10.0.2; check "latency is gone (got $avg)" between "$avg" 0 10
    ln --confirm --interface "$dev"
    check "too late to confirm" contains "$out" "Nothing to confirm"
    check "no state is left behind" [ ! -e "/run/latencyninja/$dev.confirm" ]

    # --duration rollbacks are not confirmable
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --duration 90s
    ln --confirm --interface "$dev"
    check "a --duration rollback can't be confirmed" contains "$out" "Nothing to confirm"
    ln --interface "$dev" --rollback

    # Rolling back or re-applying removes the marker
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 90s
    ln --interface "$dev" --rollback
    check "rollback removes the marker" [ ! -e "/run/latencyninja/$dev.confirm" ]
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 90s
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 30 --duration 90s
    check "re-applying with --duration removes the marker" [ ! -e "/run/latencyninja/$dev.confirm" ]
    ln --interface "$dev" --rollback

    # An earlier confirmation window survives a failed apply
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 90s
    ln_failing_tc --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --direction ingress
    check "failed apply keeps the pending confirmation" [ -f "/run/latencyninja/$dev.confirm" ]
    ln --interface "$dev" --rollback

    # Validation
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 5m --duration 5m
    check "can't be combined with --duration" contains "$out" "--confirm-within option can't be combined with --duration"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 5m --persist
    check "can't be combined with --persist" contains "$out" "--confirm-within option cannot be combined with --persist"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within abc
    check "invalid time is refused" contains "$out" "Invalid duration format"
    ln --confirm
    check "--confirm needs --interface" contains "$out" "--confirm option requires the -i|--interface option"
    ln --confirm --rollback --interface "$dev"
    check "--confirm and --rollback can't be combined" contains "$out" "--confirm option can't be combined with --rollback"
    ln --dry-run --confirm --interface "$dev"
    check "--dry-run and --confirm can't be combined" contains "$out" "only previews applying rules"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 5m --dry-run
    check "dry run explains the confirmation" contains "$out" "rolled back automatically after 5m unless confirmed with --confirm"

    # The SSH lockout guard accepts it like --duration
    ln_ssh --interface "$dev" --dst_ip 10.10.0.2 --packet_loss 50 --confirm-within 5m
    check "the SSH guard allows rules that roll back unless confirmed (exit $rc)" [ "$rc" -eq 0 ]
    ln --interface "$dev" --rollback

    # In a namespace, and from a JSON file
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 20 --confirm-within 90s
    check "works in a namespace" contains "$out" "--confirm --interface lnpeer0 --netns lnpeer"
    ln --netns lnpeer --confirm --interface lnpeer0
    check "confirmed in the namespace" contains "$out" "the rules on lnpeer0 stay in place"
    ln --netns lnpeer --interface lnpeer0 --rollback
    printf '{"interface":"%s","dst_ip":"10.10.0.2","latency":30,"confirm_within":"90s"}' "$dev" > "$work_dir/confirm.json"
    ln --json "$work_dir/confirm.json"
    check "confirm_within in a JSON file" contains "$out" "Confirm within: 90s"
    ln --interface "$dev" --rollback
}

test_probe() {
    local audit="$work_dir/probe-audit.log"
    rm -f "$audit"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2:80 --probe-count 3 --audit-log "$audit"
    check "apply succeeds (exit $rc)" [ "$rc" -eq 0 ]
    check "takes a baseline first" contains "$out" "before applying the rules"
    check "measures again with the rules" contains "$out" "with the rules applied"
    check "shows both results" contains "$out" "before rules"
    check "and the difference" contains "$out" "difference"
    local diff; diff=$(grep -E '^  difference' <<< "$out" | grep -oE '[+-][0-9.]+' | head -1)
    check "the connect time grew by about the latency (got $diff ms)" between "${diff#+}" 30 60
    check "no failures" contains "$out" "         0"
    local event; event=$(jq -c 'select(.event == "probe")' "$audit")
    check "the probe is in the audit log" [ "$(jq -r .target <<< "$event")" = "tcp://10.10.0.2:80" ]
    check "with the results" [ "$(jq -r '.applied_connect_ms | tonumber > 30' <<< "$event")" = "true" ]
    check "the baseline was taken without rules" [ "$(jq -r '.before_connect_ms | tonumber < 10' <<< "$event")" = "true" ]
    ping_stats 10.10.0.2; check "rules stay applied (got $avg)" between "$avg" 30 60

    # HTTP: first byte and total time
    nsenter --net=/run/netns/lnpeer bash -c 'cd /tmp && exec python3 -m http.server 8081 --bind 10.10.0.2 >/dev/null 2>&1' &
    local http_pid=$!
    sleep 1
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe http://10.10.0.2:8081/ --probe-count 2
    check "HTTP probe succeeds (exit $rc)" [ "$rc" -eq 0 ]
    check "shows time to first byte" contains "$out" "first byte (avg)"
    diff=$(grep -E '^  difference' <<< "$out" | grep -oE '[+-][0-9.]+' | tail -1)
    check "the total time grew (got $diff ms)" between "${diff#+}" 30 400
    kill "$http_pid" 2>/dev/null; wait "$http_pid" 2>/dev/null
    pkill -f "http.server 8081" 2>/dev/null

    # A probe that fails is a warning, the rules are still applied
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2:9 --probe-count 1
    check "a failing probe doesn't fail the apply (exit $rc)" [ "$rc" -eq 0 ]
    check "it warns" contains "$out" "could not be measured"
    ping_stats 10.10.0.2; check "rules are applied (got $avg)" between "$avg" 30 60
    ln --interface "$dev" --rollback

    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe ftp://10.10.0.2
    check "unsupported target is refused" contains "$out" "Invalid probe target: ftp://10.10.0.2"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2
    check "tcp needs a port" contains "$out" "Invalid probe target"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2:99999
    check "tcp port is checked" contains "$out" "The port must be between 1 and 65535"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2:80 --probe-count 0
    check "count of zero is refused" contains "$out" "Invalid probe count: 0"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2:80 --probe-count 101
    check "count is limited" contains "$out" "Invalid probe count: 101"
    check "nothing applied after refusals" not_contains "$(tc qdisc show dev $dev)" "prio"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe
    check "--probe needs a value" contains "$out" "The --probe option requires an argument."
    ln --dry-run --interface "$dev" --dst_ip 10.10.0.2 --latency 40 --probe tcp://10.10.0.2:80
    check "dry run mentions the probe and doesn't run it" contains "$out" "would be probed 5 times"
    check "dry run measured nothing" not_contains "$out" "before rules"

    # In a namespace the probe runs there
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 30 --probe tcp://10.10.0.1:9 --probe-count 1
    check "namespace probe runs (exit $rc)" contains "$out" "Probing tcp://10.10.0.1:9"
    ln --netns lnpeer --interface lnpeer0 --rollback

    # From a JSON file
    printf '{"interface":"%s","dst_ip":"10.10.0.2","latency":30,"probe":"tcp://10.10.0.2:80","probe_count":2}' "$dev" > "$work_dir/probe.json"
    ln --json "$work_dir/probe.json"
    check "probe in a JSON file" contains "$out" "(2 requests)"
    ln --interface "$dev" --rollback
}

test_optional_dependencies() {
    # curl is only needed for --update and --probe
    ln_without curl --interface "$dev" --dst_ip 10.10.0.2 --latency 20
    check "applying rules doesn't need curl (exit $rc)" [ "$rc" -eq 0 ]
    check "no complaint about curl" not_contains "$out" "curl"
    ln_without curl --query
    check "--query doesn't need curl (exit $rc)" [ "$rc" -eq 0 ]
    ln --interface "$dev" --rollback
    ln_without curl --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --probe tcp://10.10.0.2:80
    check "--probe needs curl" contains "$out" "'curl' command is required"
    check "nothing is applied when it's missing" not_contains "$(tc qdisc show dev $dev)" "prio"
    ln_without curl --update
    check "--update needs curl" contains "$out" "'curl' command is required"
    ln_without git --interface "$dev" --dst_ip 10.10.0.2 --latency 20
    check "git is still only for --update (exit $rc)" [ "$rc" -eq 0 ]
    ln --interface "$dev" --rollback

    # screen and tmux are only needed when they are selected
    printf '{"interface":"%s","dst_ip":"10.10.0.2","latency":30,"probe":"tcp://10.10.0.2:80"}' "$dev" > "$work_dir/probe.json"
    ln_without curl --json "$work_dir/probe.json"
    check "a probe in a JSON file also needs curl" contains "$out" "'curl' command is required for --probe"
    ln_without tmux --interface "$dev" --dst_ip 10.10.0.2 --latency 20
    check "tmux is not needed without --run-in tmux (exit $rc)" [ "$rc" -eq 0 ]
    ln --interface "$dev" --rollback
    ln_without tmux --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --run-in tmux
    check "--run-in tmux needs tmux" contains "$out" "'tmux' command is required"
    ln_without screen --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --run-in screen
    check "--run-in screen needs screen" contains "$out" "'screen' command is required"
    check "nothing is applied when it's missing" not_contains "$(tc qdisc show dev $dev)" "prio"
    ln_without tmux --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --run-in screen
    check "--run-in screen doesn't need tmux" contains "$out" "Started run"
    wait_for_rules "$dev"
    ln --interface "$dev" --rollback
    ln_without tmux --interface "$dev" --dst_ip 10.10.0.2 --latency 20 --background
    check "--background needs neither" contains "$out" "Started run"
    wait_for_rules "$dev"
    ln --interface "$dev" --rollback
    ln_without_cleanup
}

# Wait up to 30 seconds for a detached run to end; prints its id's state
wait_for_run() {
    local i
    for i in $(seq 1 60); do
        [ "$(cd "$repo_dir" && ./latencyninja --status "$1" --format json </dev/null | jq -r .state)" = "done" ] && return 0
        sleep 0.5
    done
    return 1
}

run_id_of() { grep -oE '[0-9]{8}-[0-9]{6}-[0-9]+' <<< "$1" | head -1; }

test_run_in_background() {
    local id log
    rm -rf /run/latencyninja/runs
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --probe tcp://10.10.0.2:80 --probe-count 2 --run-in background
    check "returns right away (exit $rc)" [ "$rc" -eq 0 ]
    id=$(run_id_of "$out")
    check "gives the run id" [ -n "$id" ]
    check "tells where the output is" contains "$out" "/run/latencyninja/runs/$id.log"
    check "tells how to follow it" contains "$out" "--wait $id"
    check "the run ends" wait_for_run "$id"
    check "rules are applied by the detached run" wait_for_rules "$dev"
    ping_stats 10.10.0.2; check "latency is active (got $avg)" between "$avg" 40 70
    log=$(cat "/run/latencyninja/runs/$id.log")
    check "the output is kept" contains "$log" "Applied network perturbations"
    check "including the probe" contains "$log" "difference"
    check "the log is private" [ "$(stat -c %a /run/latencyninja/runs)" = "700" ]
    check "the launcher is cleaned up" [ ! -e "/run/latencyninja/runs/$id.sh" ]

    ln --status
    check "--status lists the run" contains "$out" "$id"
    check "as done" contains "$out" "done"
    ln --status "$id"
    check "--status <id> shows the details" contains "$out" "Run $id: done (exit code 0)"
    check "the command" contains "$out" "--run-in background"
    check "and the end of the output" contains "$out" "Applied network perturbations"
    ln --status --format json
    check "--status JSON lists the runs" [ "$(jq -r --arg id "$id" '.runs[] | select(.id == $id) | .exit_code' <<< "$out")" = "0" ]
    ln --status "$id" --format json
    check "--status <id> JSON has the output" contains "$(jq -r .last_output <<< "$out")" "Applied"
    ln --wait "$id"
    check "--wait returns the output and exit code (exit $rc)" [ "$rc" -eq 0 ]
    check "--wait shows the output" contains "$out" "Applied network perturbations"
    check "and the result" contains "$out" "finished with exit code 0"

    # A failing run: the exit code is kept
    local failing="20260101-000000-1"
    mkdir -p /run/latencyninja/runs
    printf 'mode=background\nstate=done\nrc=3\nstarted=x\n' > "/run/latencyninja/runs/$failing.status"
    echo "boom" > "/run/latencyninja/runs/$failing.log"
    ln --wait "$failing"
    check "--wait exits with the exit code of the run (exit $rc)" [ "$rc" -eq 3 ]
    check "and shows its output" contains "$out" "boom"
    # A run that was killed
    local killed="20260101-000000-2"
    printf 'mode=background\nstate=running\npid=999999\nstarted=x\n' > "/run/latencyninja/runs/$killed.status"
    : > "/run/latencyninja/runs/$killed.log"
    ln --wait "$killed"
    check "a killed run is reported (exit $rc)" contains "$out" "did not finish: killed"
    rm -f "/run/latencyninja/runs/$failing".* "/run/latencyninja/runs/$killed".*

    ln --wait 20260101-000000-9
    check "unknown run is refused" contains "$out" "Run not found"
    ln --wait ../../etc/passwd
    check "run ids are validated" contains "$out" "Invalid run id"
    ln --status "x; touch /tmp/lntest-pwned"
    check "run ids are never executed" [ ! -e /tmp/lntest-pwned ]
    ln --wait
    check "--wait needs an id" contains "$out" "The --wait option requires an argument."

    # Validation happens in the foreground
    ln --interface "$dev" --rollback
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency abc --run-in background
    check "mistakes are reported right away (exit $rc)" contains "$out" "Invalid latency format"
    check "without starting a run" not_contains "$out" "Started run"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --run-in nohup
    check "unknown mode is refused" contains "$out" "Invalid --run-in value: nohup"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --run-in background --dry-run
    check "can't be combined with --dry-run" contains "$out" "can't be combined with --dry-run"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --run-in
    check "--run-in needs a value" contains "$out" "The --run-in option requires an argument."
    check "nothing applied after refusals" not_contains "$(tc qdisc show dev $dev)" "prio"

    # Combined with the dead-man switch: confirm the detached rules later
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --confirm-within 90s --background
    id=$(run_id_of "$out")
    check "the run ends" wait_for_run "$id"
    ln --confirm --interface "$dev"
    check "rules applied by a detached run can be confirmed (exit $rc)" contains "$out" "stay in place"
    ln --interface "$dev" --rollback
    ln --check
    check "--check finds no state left over" not_contains "$out" "$dev"
}

test_run_in_session() {
    local tool="$1" id
    command -v "$tool" &>/dev/null || return 77
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 50 --run-in "$tool"
    check "starts a $tool session (exit $rc)" [ "$rc" -eq 0 ]
    id=$(run_id_of "$out")
    check "tells how to attach" contains "$out" "latencyninja-$id"
    check "the run ends" wait_for_run "$id"
    check "rules are applied" wait_for_rules "$dev"
    check "the output is kept" contains "$(cat /run/latencyninja/runs/$id.log)" "Applied network perturbations"
    ln --status "$id"
    check "the mode is shown" contains "$out" "Mode:      $tool latencyninja-$id"
    ln --interface "$dev" --rollback
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 50 --run-in "$tool"
    id=$(run_id_of "$out")
    check "a namespace run ends" wait_for_run "$id"
    check "the detached run applied the rules inside the namespace" contains "$(nsenter --net=/run/netns/lnpeer tc qdisc show dev lnpeer0)" "prio"
    check "and not on the host" not_contains "$(tc qdisc show dev lnpeer0 2>&1)" "prio"
    check "the run shows its namespace" contains "$(cd "$repo_dir" && ./latencyninja --status "$id" </dev/null)" "network namespace lnpeer"
    ln --netns lnpeer --interface lnpeer0 --rollback
}

test_run_in_tmux() { test_run_in_session tmux; }
test_run_in_screen() { test_run_in_session screen; }

test_run_in_namespace() {
    local id
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 50 --background
    id=$(run_id_of "$out")
    check "the run ends" wait_for_run "$id"
    check "rules are applied in the namespace" contains "$(nsenter --net=/run/netns/lnpeer tc qdisc show dev lnpeer0)" "prio"
    check "and not on the host" not_contains "$(tc qdisc show dev lnpeer0 2>&1)" "prio"
    ln --netns lnpeer --interface lnpeer0 --rollback
    printf '{"netns":"lnpeer","interface":"lnpeer0","dst_ip":"10.10.0.1","latency":30}' > "$work_dir/ns-run.json"
    ln --json "$work_dir/ns-run.json" --background
    id=$(run_id_of "$out")
    check "a namespace from a JSON file works too" wait_for_run "$id"
    check "the run succeeded" contains "$(cd "$repo_dir" && ./latencyninja --status "$id" </dev/null)" "exit code 0"
    check "applied in the namespace" contains "$(nsenter --net=/run/netns/lnpeer tc qdisc show dev lnpeer0)" "prio"
    ln --netns lnpeer --interface lnpeer0 --rollback
}

# ---------- tests: updater ----------

test_update() {
    curl -sfL --max-time 5 https://raw.githubusercontent.com/kyndryl-open-source/latencyninja/main/version.txt >/dev/null || return 77
    local user="${SUDO_USER:-}"
    [ -z "$user" ] && return 77
    local clone="$work_dir/updclone"
    rm -rf "$clone"; mkdir -p "$work_dir"; chmod 777 "$work_dir"
    # Clone from GitHub (so 'git pull' has a real upstream), then overlay the local code under test
    sudo -u "$user" git clone -q --depth 1 https://github.com/kyndryl-open-source/latencyninja.git "$clone" || return 77
    cp "$repo_dir/latencyninja" "$clone/" && cp "$repo_dir"/inc/*.sh "$clone/inc/"

    echo "9.99" > "$clone/version.txt"
    out=$(cd "$clone" && SUDO_USER="$user" ./latencyninja --update </dev/null 2>&1)
    check "newer local version: no update needed" contains "$out" "No update needed"

    echo "1.0" > "$clone/version.txt"
    out=$(cd "$clone" && echo n | SUDO_USER="$user" ./latencyninja --update 2>&1)
    check "older version: update offered" contains "$out" "A new version is available"
    check "declining cancels" contains "$out" "Update cancelled"
}

# ---------- main ----------

all_tests=(
    cli_version cli_help cli_requires_root validation_errors 
    latency_both latency_egress latency_ingress jitter packet_loss duplicate corrupt reorder combined 
    target_ports target_multiple target_src_only target_src_and_dst target_src_wrong 
    json_import query rollback reapply_replaces 
    backup_and_logging backup_defaults failed_apply_not_logged 
    bond_directions bond_ports_and_failover wireguard_directions wireguard_ports_and_loss 
    multi_interface interface_names multiple_addresses run_from_other_dir 
    snapshot_save_restore snapshot_scoped snapshot_clean_state snapshot_restore_backup snapshot_errors 
    persist_wireguard_recreate persist_bond_recreate persist_rollback_removes persist_update_and_note 
    persist_restore_keeps_persistence 
    rate_egress rate_ingress rate_both_directions rate_port_and_units rate_validation 
    profile_apply profile_override profile_list_and_errors profile_custom profile_saved_as_values profile_and_rate_json 
    duration_expires_to_clean duration_restores_previous duration_cancelled duration_multi_interface duration_validation 
    show_interfaces show_interfaces_requires_root 
    netns_apply netns_isolation netns_timed_rollback netns_snapshot pid_target namespace_errors container_target 
    json_every_option json_persist_and_profile json_namespaces json_errors profile_unknown_key 
    persist_netns persist_container snapshot_all_namespaces namespace_aliases 
    validation_normalization dry_run failed_apply_undone failed_apply_timer_kept bad_logging_path options_without_value value_limits foreign_qdiscs ssh_guard ssh_guard_duration check_clean check_clean_namespace 
    json_output stats audit_log confirm_within probe optional_dependencies run_in_background run_in_tmux run_in_screen run_in_namespace 
    update
)

# Tests that need the real systemd (persistence units, a real timer), containers or other state shared with the
# host can't run in an isolated network namespace; everything else can run in parallel (see tests/run_parallel.sh).
# In a shard, timers are started by stand-ins for systemd-run and systemctl (tests/shim).
real_systemd_tests=" duration_expires_to_clean netns_timed_rollback check_clean check_clean_namespace "
# Tests that only mention --persist or the like in a validation, and are safe in a shard
shard_safe_tests=" confirm_within optional_dependencies dry_run json_errors failed_apply_undone "
test_class() {
    local body; body=$(declare -f "test_$1")
    [[ "$shard_safe_tests" == *" $1 "* ]] && { echo parallel; return; }
    if [[ "$real_systemd_tests" == *" $1 "* || "$1" == *persist* || "$1" == *update* ]] ||
       grep -qE -- 'persist|\bpid\b|--timed|systemctl|--check|--clean|podman|docker|container|latencyninja_tc_backup|reboot' <<< "$body"; then
        echo serial
    else
        echo parallel
    fi
}

# Tests that don't measure traffic or wait for timers: a fast smoke run for development (filter @quick)
test_is_quick() {
    ! declare -f "test_$1" | grep -qE 'ping_stats|throughput|tcp_rtt|sleep|wait_for|--duration|--confirm-within'
}

if [ "$filter" = "--classify" ]; then
    for t in "${all_tests[@]}"; do echo "$t $(test_class "$t")"; done
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "Setting up test topology..."
bash "$tests_dir/netns_setup.sh" up || exit 1
trap 'bash "$tests_dir/netns_setup.sh" down' EXIT

for t in ${LN_TESTS:-"${all_tests[@]}"}; do
    if [ "$filter" = "@quick" ]; then test_is_quick "$t" || continue; fi
    run_test "$t"
done

echo
echo "Passed: $pass  Failed: $fail  Skipped: $skip"
[ "$fail" -gt 0 ] && printf 'Failed tests: %s\n' "${failed_tests[*]}"
[ "$fail" -eq 0 ]
