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
    out=$(cd "$repo_dir" && ./latencyninja "$@" </dev/null 2>&1)
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
    raw=$(ping -c "$count" -i "$interval" -w $((count / 5 + 5)) "$target" 2>&1)
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
not_contains() { ! grep -qF -- "$2" <<< "$1"; }

run_test() {
    local name="$1"
    [ -n "$filter" ] && [[ "$name" != *"$filter"* ]] && return
    current_test="$name"
    test_ok=1
    out=""
    printf '%s\n' "$(yellow "▶ $name")"
    rollback
    "test_$name"
    local status=$?
    rollback
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
    check "default log at /tmp/latencyninja.log" [ -f /tmp/latencyninja.log ]
}

test_failed_apply_not_logged() {
    # If tc setup fails the run must not be reported/logged as applied
    rm -f "$work_dir/fail.log"; mkdir -p "$work_dir"
    ln --interface "$dev" --dst_ip 10.10.0.2 --latency 10 --corrupt 150 --direction ingress --logging "$work_dir/fail.log"
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

test_show_interfaces_non_root() {
    [ -z "${SUDO_USER:-}" ] && return 77
    ln --interface bond0 --dst_ip 10.40.0.2 --latency 10 --persist
    out=$(cd "$repo_dir" && sudo -u "$SUDO_USER" ./latencyninja --show-interfaces </dev/null 2>&1); rc=$?
    check "works without root (exit $rc)" [ "$rc" -eq 0 ]
    check "rules visible without root" contains "$(grep '^bond0 ' <<< "$out")" "rules (both)"
    check "notes root is needed for persistence" contains "$out" "Run as root"
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
    check "host snapshot excludes the namespace" [ "$(grep -c '^\[interface ' "$work_dir/host-snap")" -eq 1 ]
    ln --netns lnpeer --rollback --interface "$dev"
    check "namespace rollback doesn't unpersist the host" [ -f "/etc/latencyninja/persist/$dev.args" ]
    ping_stats 10.10.0.3; check "host rules still active (got $avg)" between "$avg" 90 130
    nsenter --net=/run/netns/lnpeer ip link delete "$dev"
}

test_netns_timed_rollback() {
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 100 --duration 3s
    check "timer scheduled" contains "$out" "Rollback of lnpeer0 scheduled"
    check "timer unit is namespace specific" contains "$out" "latencyninja-rollback-netns"
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
    check "snapshot records the namespace" contains "$(cat "$work_dir/ns-snap")" "[namespace netns-lnpeer]"
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
    ln --netns lnpeer --interface lnpeer0 --dst_ip 10.10.0.1 --latency 10 --persist
    check "--persist refused in a namespace" contains "$out" "--persist option isn't supported"
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
    sleep 6
    ping_stats "$cip"; check "timed rollback restored the previous container rules (got $avg)" between "$avg" 90 130
    ln --container lntest --rollback --interface eth0
    ping_stats "$cip"; check "rollback in the container (got $avg)" between "$avg" 0 10
    "$rt" rm -f -t 0 lntest &>/dev/null || "$rt" rm -f lntest &>/dev/null
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

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "Setting up test topology..."
bash "$tests_dir/netns_setup.sh" up || exit 1
trap 'bash "$tests_dir/netns_setup.sh" down' EXIT

for t in \
    cli_version cli_help cli_requires_root validation_errors \
    latency_both latency_egress latency_ingress jitter packet_loss duplicate corrupt reorder combined \
    target_ports target_multiple target_src_only target_src_and_dst target_src_wrong \
    json_import query rollback reapply_replaces \
    backup_and_logging backup_defaults failed_apply_not_logged \
    bond_directions bond_ports_and_failover wireguard_directions wireguard_ports_and_loss \
    multi_interface interface_names multiple_addresses run_from_other_dir \
    snapshot_save_restore snapshot_scoped snapshot_clean_state snapshot_restore_backup snapshot_errors \
    persist_wireguard_recreate persist_bond_recreate persist_rollback_removes persist_update_and_note \
    persist_restore_keeps_persistence \
    rate_egress rate_ingress rate_both_directions rate_port_and_units rate_validation \
    profile_apply profile_override profile_list_and_errors profile_custom profile_saved_as_values profile_and_rate_json \
    duration_expires_to_clean duration_restores_previous duration_cancelled duration_multi_interface duration_validation \
    show_interfaces show_interfaces_non_root \
    netns_apply netns_isolation netns_timed_rollback netns_snapshot pid_target namespace_errors container_target \
    update
do
    run_test "$t"
done

echo
echo "Passed: $pass  Failed: $fail  Skipped: $skip"
[ "$fail" -gt 0 ] && printf 'Failed tests: %s\n' "${failed_tests[*]}"
[ "$fail" -eq 0 ]
