#!/usr/bin/env bash
#
# Run the functional test suite in parallel. Run as root inside a disposable Linux VM:
#
#   sudo bash tests/run_parallel.sh [shards]     # default: one shard per CPU (at least 2, at most 6)
#
# Tests that need systemd timers or units, persistence, containers or other state shared with the host run
# one after the other in the host's namespaces; all the others are spread over isolated shards (see shard.sh),
# each with its own network namespace and copy of the test topology. The split comes from test_class in
# run_tests.sh. tests/weights.txt ("<test> <seconds>") balances the shards; tests not listed count as 4 seconds.

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
tests_dir="$repo_dir/tests"
shards="${1:-$(nproc)}"
[ "$shards" -lt 2 ] && shards=2
[ "$shards" -gt 6 ] && shards=6
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

declare -A weight=() lists=() totals=()
while read -r name seconds; do
    [ -n "$name" ] && weight[$name]="$seconds"
done < "$tests_dir/weights.txt" 2>/dev/null

serial=() parallel=()
while read -r name class; do
    [ "$class" = "serial" ] && serial+=("$name") || parallel+=("$name")
done < <(bash "$tests_dir/run_tests.sh" --classify)

# Longest tests first, each to the shard with the least work so far
for ((i = 0; i < shards; i++)); do totals[$i]=0; lists[$i]=""; done
while read -r seconds name; do
    best=0
    for ((i = 1; i < shards; i++)); do [ "${totals[$i]}" -lt "${totals[$best]}" ] && best=$i; done
    lists[$best]+="$name "
    totals[$best]=$(( ${totals[$best]} + seconds ))
done < <(for name in "${parallel[@]}"; do echo "${weight[$name]:-4} $name"; done | sort -rn)

log_dir=$(mktemp -d /tmp/lnparallel.XXXXXX)
started=$SECONDS
pids=()
echo "Running ${#parallel[@]} tests in $shards isolated shards and ${#serial[@]} in the host namespace..."
for ((i = 0; i < shards; i++)); do
    LN_TESTS="${lists[$i]}" unshare --mount --net --pid --fork --mount-proc bash "$tests_dir/shard.sh" > "$log_dir/shard$i.log" 2>&1 &
    pids+=($!)
done
LN_TESTS="${serial[*]}" bash "$tests_dir/run_tests.sh" > "$log_dir/serial.log" 2>&1 &
pids+=($!)

status=0
for pid in "${pids[@]}"; do wait "$pid" || status=1; done

pass=0 fail=0 skip=0 failed=()
for log in "$log_dir"/*.log; do
    echo
    echo "===== $(basename "$log" .log) ====="
    cat "$log"
    read -r p f s < <(sed -n 's/^Passed: \([0-9]*\)  Failed: \([0-9]*\)  Skipped: \([0-9]*\)/\1 \2 \3/p' "$log")
    pass=$((pass + ${p:-0})); fail=$((fail + ${f:-0})); skip=$((skip + ${s:-0}))
    grep -q '^Passed:' "$log" || { echo "No result in $log: the shard did not finish."; status=1; }
    failed+=($(sed -n 's/^Failed tests: //p' "$log"))
done
echo
echo "Passed: $pass  Failed: $fail  Skipped: $skip  ($((SECONDS - started))s)"
[ "${#failed[@]}" -gt 0 ] && printf 'Failed tests: %s\n' "${failed[*]}"
rm -rf "$log_dir"
[ "$status" -eq 0 ] && [ "$fail" -eq 0 ]
