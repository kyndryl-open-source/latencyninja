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

# --run-in (or --background) runs the whole command detached, so a dropped terminal or SSH session doesn't end it
# (for example while --probe is measuring or a --confirm-within countdown is running):
#
#   --run-in background   a detached process (no extra tools needed)
#   --run-in screen       a detached screen session, attach with: screen -r latencyninja-<id>
#   --run-in tmux         a detached tmux session, attach with: tmux attach -t latencyninja-<id>
#
# The command is validated first, in the foreground, so mistakes are reported right away. It then runs again
# in the detached process, which writes its output to $runs_dir/<id>.log and its state to $runs_dir/<id>.status
# (runs are kept until the next reboot). --status lists the runs and --wait <id> waits for one to end,
# prints its output and exits with its exit code.

# Function to validate --run-in
validate_run_in() {
    [ -z "$run_in" ] && return 0
    [[ "$run_in" =~ ^(background|screen|tmux)$ ]] || die "Invalid --run-in value: $run_in. Valid options are: background, screen or tmux."
    if [ "$run_in" = "screen" ] || [ "$run_in" = "tmux" ]; then
        command -v "$run_in" &>/dev/null || die "The '$run_in' command is required for --run-in $run_in but it's not installed. Please install it and retry."
    fi
    [ "$dry_run" -eq 1 ] && die "The --run-in option can't be combined with --dry-run, which only shows what would be applied."
    return 0
}

# Function to write a field of a run's status file, replacing it if it exists
run_set() {
    local id="$1" key="$2" value="$3" file="$runs_dir/$1.status"
    touch "$file"
    { grep -v "^$key=" "$file"; echo "$key=$value"; } > "$file.tmp" 2>/dev/null
    mv -f "$file.tmp" "$file"
}

# Function to read a field of a run's status file
run_get() {
    local id="$1" key="$2"
    sed -n "s/^$key=//p" "$runs_dir/$id.status" 2>/dev/null | tail -n 1
}

# Function to detach: start this command again (without --run-in) in the background, a screen or a tmux session
detach_run() {
    local args=() arg skip=0 id session command_args=() ns_file

    for arg in "$@"; do
        if [ "$skip" -eq 1 ]; then skip=0; continue; fi
        case "$arg" in
            --run-in) skip=1 ;;
            --background) ;;
            *) args+=("$arg") ;;
        esac
    done
    id="$(date +%Y%m%d-%H%M%S)-$RANDOM"
    session="latencyninja-$id"

    mkdir -p "$runs_dir" && chmod 700 "$runs_dir"
    : > "$runs_dir/$id.log"
    {
        echo "mode=$run_in"
        echo "state=starting"
        echo "started=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "user=$(audit_actor_name)"
        echo "interface=$eth_interface"
        echo "namespace=${LATENCYNINJA_NETNS_DESC:-}"
        echo "command=$audit_command"
    } > "$runs_dir/$id.status"

    # A tmux or screen server that is already running lives in the host's namespace, so inside a namespace the
    # command enters it again itself, with the variables that tell Latency Ninja it is there
    if in_namespace; then
        ns_file=$(ref_to_nsfile "$LATENCYNINJA_NETNS_REF")
        [ -n "$ns_file" ] || die "The target of $LATENCYNINJA_NETNS_OPT $LATENCYNINJA_NETNS_VAL is gone."
        command_args=(nsenter --net="$ns_file" env "LATENCYNINJA_NETNS_KEY=$LATENCYNINJA_NETNS_KEY"
            "LATENCYNINJA_NETNS_DESC=$LATENCYNINJA_NETNS_DESC" "LATENCYNINJA_NETNS_OPT=$LATENCYNINJA_NETNS_OPT"
            "LATENCYNINJA_NETNS_VAL=$LATENCYNINJA_NETNS_VAL" "LATENCYNINJA_NETNS_REF=$LATENCYNINJA_NETNS_REF")
    fi
    command_args+=(bash "$script_path" "${args[@]}" --run-id "$id")
    # The launcher keeps the output (also shown live in a session) and records how the command ended. It is a file
    # so the same command works in the background, in screen and in tmux without any quoting of its own.
    {
        echo '#!/bin/bash'
        printf 'log=%q status=%q launcher=%q\n' "$runs_dir/$id.log" "$runs_dir/$id.status" "$runs_dir/$id.sh"
        printf '%q ' "${command_args[@]}"
        echo '2>&1 | tee -a "$log"'
        echo 'rc=${PIPESTATUS[0]}'
        echo '{ grep -v "^\(state\|rc\|finished\)=" "$status"; echo "state=done"; echo "rc=$rc"; echo "finished=$(date "+%Y-%m-%d %H:%M:%S")"; } > "$status.tmp" && mv -f "$status.tmp" "$status"'
        echo 'rm -f "$launcher"'
        echo 'exit "$rc"'
    } > "$runs_dir/$id.sh"
    chmod 700 "$runs_dir/$id.sh"

    case "$run_in" in
        background)
            setsid bash "$runs_dir/$id.sh" </dev/null >/dev/null 2>&1 &
            disown 2>/dev/null
            ;;
        screen)
            screen -dmS "$session" bash "$runs_dir/$id.sh" ||
                { run_set "$id" state failed; die "Could not start the screen session."; }
            ;;
        tmux)
            tmux new-session -d -s "$session" "bash $runs_dir/$id.sh" ||
                { run_set "$id" state failed; die "Could not start the tmux session."; }
            ;;
    esac
    run_set "$id" session "$session"

    echo "Started run $id ($run_in)."
    echo "  Output:   $runs_dir/$id.log"
    case "$run_in" in
        screen) echo "  Attach:   screen -r $session   (detach again with Ctrl-a d)" ;;
        tmux) echo "  Attach:   tmux attach -t $session   (detach again with Ctrl-b d)" ;;
    esac
    echo "  Follow:   sudo $0 --wait $id"
    echo "  Status:   sudo $0 --status $id"
}

# Function to register the detached run this process is (it was started with --run-id by detach_run)
register_run() {
    [ -n "$run_id" ] || return 0
    [[ "$run_id" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || die "Invalid run id: $run_id."
    [ -f "$runs_dir/$run_id.status" ] || return 0
    run_set "$run_id" state running
    run_set "$run_id" pid "$$"
}

# Function to check a run id given to --status or --wait
check_run_id() {
    [[ "$1" =~ ^[0-9]{8}-[0-9]{6}-[0-9]+$ ]] || die "Invalid run id: $1. See: sudo $0 --status"
    [ -f "$runs_dir/$1.status" ] || die "Run not found: $1. See: sudo $0 --status"
}

# Function to tell whether a run is still going. A run whose process is gone without a final state was killed.
run_state() {
    local id="$1" state pid
    state=$(run_get "$id" state)
    if [ "$state" = "running" ] || [ "$state" = "starting" ]; then
        pid=$(run_get "$id" pid)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            sleep 0.5
            [ "$(run_get "$id" state)" = "done" ] && { echo done; return; }
            state="killed"
        fi
    fi
    echo "${state:-unknown}"
}

# Function to handle --status: list the detached runs, or show one with the end of its output
run_status() {
    local id="$1" file state rc

    if [ -n "$id" ]; then
        check_run_id "$id"
        state=$(run_state "$id")
        if [ "$output_format" = "json" ]; then
            run_json "$id" "$state" "$(tail -n 20 "$runs_dir/$id.log" 2>/dev/null)"
            return 0
        fi
        echo
        echo "Run $id: $state$([ "$state" = "done" ] && echo " (exit code $(run_get "$id" rc))")"
        echo "  Mode:      $(run_get "$id" mode) $(run_get "$id" session)"
        echo "  Started:   $(run_get "$id" started)"
        [ -n "$(run_get "$id" finished)" ] && echo "  Finished:  $(run_get "$id" finished)"
        echo "  User:      $(run_get "$id" user)"
        [ -n "$(run_get "$id" namespace)" ] && echo "  Namespace: $(run_get "$id" namespace)"
        echo "  Command:   $(run_get "$id" command)"
        echo "  Output:    $runs_dir/$id.log"
        echo
        echo "Last lines of the output:"
        tail -n 20 "$runs_dir/$id.log" 2>/dev/null | sed 's/^/  | /'
        echo
        return 0
    fi

    if [ "$output_format" = "json" ]; then
        local items=()
        for file in "$runs_dir"/*.status; do
            [ -f "$file" ] || continue
            id=$(basename "$file" .status)
            items+=("$(run_json "$id" "$(run_state "$id")" "")")
        done
        printf '%s\n' "${items[@]}" | $jq_path -s '{runs: .}'
        return 0
    fi
    echo
    printf '%-26s %-11s %-11s %-6s %-20s %s\n' "RUN" "STATE" "MODE" "EXIT" "STARTED" "INTERFACE"
    local found=0
    for file in "$runs_dir"/*.status; do
        [ -f "$file" ] || continue
        found=1
        id=$(basename "$file" .status)
        state=$(run_state "$id")
        rc=$(run_get "$id" rc)
        printf '%-26s %-11s %-11s %-6s %-20s %s\n' "$id" "$state" "$(run_get "$id" mode)" "${rc:--}" "$(run_get "$id" started)" "$(run_get "$id" interface)"
    done
    [ "$found" -eq 0 ] && echo "No detached runs. Start one with --run-in background, screen or tmux."
    echo
}

# Function to print one run as a JSON object
run_json() {
    local id="$1" state="$2" tail_output="$3"
    $jq_path -n --arg id "$id" --arg state "$state" --arg mode "$(run_get "$id" mode)" --arg session "$(run_get "$id" session)" \
        --arg started "$(run_get "$id" started)" --arg finished "$(run_get "$id" finished)" --arg rc "$(run_get "$id" rc)" \
        --arg user "$(run_get "$id" user)" --arg interface "$(run_get "$id" interface)" --arg namespace "$(run_get "$id" namespace)" \
        --arg command "$(run_get "$id" command)" --arg log "$runs_dir/$id.log" --arg output "$tail_output" \
        '{id: $id, state: $state, mode: $mode, session: $session, started: $started, finished: $finished,
          exit_code: (if $rc == "" then null else ($rc | tonumber) end), user: $user, interface: $interface,
          namespace: $namespace, command: $command, log: $log}
         + (if $output == "" then {} else {last_output: $output} end)
         | with_entries(select(.value != ""))'
}

# Function to handle --wait: wait for a run to end, show its output and exit with its exit code
run_wait() {
    local id="$1" state rc

    check_run_id "$id"
    echo "Waiting for run $id (Ctrl-C stops waiting, the run goes on)..."
    while :; do
        state=$(run_state "$id")
        case "$state" in
            done|killed|failed) break ;;
        esac
        sleep 1
    done
    echo
    cat "$runs_dir/$id.log" 2>/dev/null
    if [ "$state" = "done" ]; then
        rc=$(run_get "$id" rc)
        echo
        echo "Run $id finished with exit code ${rc:-?}."
        return "${rc:-1}"
    fi
    echo
    echo "Run $id did not finish: $state."
    return 1
}
