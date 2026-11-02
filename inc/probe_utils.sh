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

# --probe measures what the rules do to a real application, not only to ICMP: it connects to a target with curl
# before the rules are applied (a baseline, taken after any earlier rules were removed) and again once they are
# in place, then shows the difference. The target is one of:
#
#   http://host[:port][/path], https://...   a full HTTP request: connect time, time to first byte and total time
#   tcp://host:port                          a TCP connection only: connect time (databases, MQ, mainframe gateways...)
#
# --probe-count sets the number of requests per measurement (default 5). A probe that fails is a warning, it never
# stops the rules from being applied. The probe runs in the namespace of --netns, --pid or --container.

declare -g probe_runs=()  # the measurements: "<label>|<ok>|<failed>|<connect avg>|<first byte avg>|<total avg>" in ms

# Function to validate --probe and --probe-count
validate_probe() {
    [ -z "$probe" ] && return 0
    case "$probe" in
        http://?*|https://?*) probe_kind="http" ;;
        tcp://?*:[0-9]*|tcp://\[*\]:[0-9]*) probe_kind="tcp" ;;
        *) die "Invalid probe target: $probe. Use http://host[:port][/path], https://host[:port][/path] or tcp://host:port." ;;
    esac
    if [ "$probe_kind" = "tcp" ]; then
        local port="${probe##*:}"
        [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] ||
            die "Invalid probe target: $probe. The port must be between 1 and 65535."
    fi
    [[ "$probe_count" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$probe_count))" -ge 1 ] && [ "$((10#$probe_count))" -le 100 ] ||
        die "Invalid probe count: $probe_count. Use a number between 1 and 100."
    probe_count=$((10#$probe_count))
    # The target can also come from a JSON file, where the command line was not scanned for it
    [ -n "$curl_path" ] || curl_path=$(command -v curl) || die "The 'curl' command is required for --probe but it's not installed. Please install it and retry."
}

# Function to take one sample and print "<connect> <first byte> <total>" in ms, or fail
probe_sample() {
    local output
    if [ "$probe_kind" = "tcp" ]; then
        # curl's telnet scheme opens the TCP connection and nothing else; with no input it closes it again.
        # A connection that fails reports a connect time of 0.
        output=$($curl_path -sS -o /dev/null --connect-timeout 5 --max-time 5 -w '%{time_connect}' "telnet://${probe#tcp://}" 2>/dev/null </dev/null)
        [[ "$output" =~ ^[0-9.]+$ ]] && awk -v c="$output" 'BEGIN{exit !(c > 0)}' || return 1
        awk -v c="$output" 'BEGIN{printf "%.3f %.3f %.3f\n", c*1000, c*1000, c*1000}'
    else
        output=$($curl_path -sS -o /dev/null --connect-timeout 5 --max-time 15 -w '%{time_connect} %{time_starttransfer} %{time_total}' "$probe" 2>/dev/null) || return 1
        [[ "$output" =~ ^[0-9.]+\ [0-9.]+\ [0-9.]+$ ]] || return 1
        awk -v o="$output" 'BEGIN{split(o, t, " "); printf "%.3f %.3f %.3f\n", t[1]*1000, t[2]*1000, t[3]*1000}'
    fi
}

# Function to measure the probe target probe_count times and record the averages under a label
probe_measure() {
    local label="$1" i sample ok=0 failed=0 sums
    local connect_sum=0 first_byte_sum=0 total_sum=0 connect first_byte total

    for ((i = 0; i < probe_count; i++)); do
        if sample=$(probe_sample); then
            read -r connect first_byte total <<< "$sample"
            connect_sum=$(awk -v a="$connect_sum" -v b="$connect" 'BEGIN{print a+b}')
            first_byte_sum=$(awk -v a="$first_byte_sum" -v b="$first_byte" 'BEGIN{print a+b}')
            total_sum=$(awk -v a="$total_sum" -v b="$total" 'BEGIN{print a+b}')
            ok=$((ok + 1))
        else
            failed=$((failed + 1))
        fi
    done
    if [ "$ok" -gt 0 ]; then
        sums=$(awk -v n="$ok" -v a="$connect_sum" -v b="$first_byte_sum" -v c="$total_sum" 'BEGIN{printf "%.1f|%.1f|%.1f", a/n, b/n, c/n}')
    else
        sums="-|-|-"
    fi
    probe_runs+=("$label|$ok|$failed|$sums")
}

# Function to take the baseline before the rules are applied
probe_baseline() {
    [ -n "$probe" ] || return 0
    echo "Probing $probe ($probe_count requests) before applying the rules..."
    probe_measure "before rules"
}

# Function to measure again with the rules in place and show both results with their difference
probe_compare() {
    [ -n "$probe" ] || return 0
    local label ok failed c f t bc bf bt run delta_connect delta_total
    echo "Probing $probe ($probe_count requests) with the rules applied..."
    probe_measure "with rules"
    IFS='|' read -r label ok failed bc bf bt <<< "${probe_runs[0]}"
    IFS='|' read -r label ok failed c f t <<< "${probe_runs[1]}"
    echo
    if [ "$probe_kind" = "tcp" ]; then
        printf '  %-14s %14s %8s\n' "" "connect (avg)" "failed"
    else
        printf '  %-14s %14s %16s %12s %8s\n' "" "connect (avg)" "first byte (avg)" "total (avg)" "failed"
    fi
    for run in "${probe_runs[@]}"; do
        IFS='|' read -r label ok failed c f t <<< "$run"
        if [ "$probe_kind" = "tcp" ]; then
            printf '  %-14s %11s ms %8s\n' "$label" "$c" "$failed"
        else
            printf '  %-14s %11s ms %13s ms %9s ms %8s\n' "$label" "$c" "$f" "$t" "$failed"
        fi
    done
    if [ "$bc" != "-" ] && [ "$c" != "-" ]; then
        delta_connect=$(awk -v a="$c" -v b="$bc" 'BEGIN{printf "%+.1f", a-b}')
        delta_total=$(awk -v a="$t" -v b="$bt" 'BEGIN{printf "%+.1f", a-b}')
        if [ "$probe_kind" = "tcp" ]; then
            printf '  %-14s %11s ms\n' "difference" "$delta_connect"
        else
            printf '  %-14s %11s ms %13s ms %9s ms\n' "difference" "$delta_connect" \
                "$(awk -v a="$f" -v b="$bf" 'BEGIN{printf "%+.1f", a-b}')" "$delta_total"
        fi
    else
        echo "  Warning: the probe could not be measured both times, so there is no difference to show." >&2
    fi
    echo
    audit_event probe "target=$probe" "count=$probe_count" "before_connect_ms=${bc/#-/}" "before_total_ms=${bt/#-/}" "applied_connect_ms=${c/#-/}" "applied_total_ms=${t/#-/}"
}
