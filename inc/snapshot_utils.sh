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

# Snapshot file format (one argument per line, so no shell evaluation is needed to restore):
#
#   # Latency Ninja snapshot
#   [scope all]                 <- or [scope <interface>] when saved with --interface
#   [namespace container:web]   <- only when saved inside a container or namespace
#   [interface eth0]
#   --interface
#   eth0
#   --latency
#   30
#   [end]
#   [interface eth0 @container:web]   <- host snapshots also include containers and namespaces
#   ...
#   [end]
#   # ... human readable tc dump as comments ...

# Function to print the applied configuration as canonical arguments, one per line
build_canonical_args() {
    echo "--interface"; echo "$eth_interface"
    [ -n "$src_ip_arg" ] && { echo "--src_ip"; echo "$src_ip_arg"; }
    [ -n "$dst_ip_arg" ] && { echo "--dst_ip"; echo "$dst_ip_arg"; }
    echo "--direction"; echo "$direction"
    [ -n "$latency" ] && { echo "--latency"; echo "$latency"; }
    [ -n "$jitter" ] && { echo "--jitter"; echo "$jitter"; }
    [ -n "$packet_loss" ] && { echo "--packet_loss"; echo "$packet_loss"; }
    [ -n "$duplicate" ] && { echo "--duplicate"; echo "$duplicate"; }
    [ -n "$corrupt" ] && { echo "--corrupt"; echo "$corrupt"; }
    [ -n "$reorder" ] && { echo "--reorder"; echo "$reorder"; }
    [ -n "$rate" ] && { echo "--rate"; echo "$rate"; }
    [ -n "$backup_dir" ] && { echo "--backup"; echo "$backup_dir"; }
    [ -n "$log_file" ] && { echo "--logging"; echo "$log_file"; }
}

# Function to check that saved arguments only contain options that apply rules
# (prevents a crafted snapshot from triggering e.g. --restore loops or --update)
validate_saved_args() {
    local expect_value=0 arg
    for arg in "$@"; do
        if [ "$expect_value" -eq 1 ]; then
            expect_value=0
            continue
        fi
        case "$arg" in
            --interface|--src_ip|--dst_ip|--direction|--latency|--jitter|--packet_loss|--duplicate|--corrupt|--reorder|--rate|--backup|--logging)
                expect_value=1 ;;
            *) return 1 ;;
        esac
    done
}

# Function to record the configuration currently applied to an interface (cleared on reboot)
save_runtime_state() {
    local interface="$1"
    mkdir -p "$state_dir" && chmod 700 "$state_dir"
    build_canonical_args > "$state_dir/$interface.args"
    # Remember how to re-enter this namespace, so host snapshots can include and restore it.
    # A container or named namespace reference is kept over a process one, which is less stable.
    if in_namespace && { [ ! -f "$state_dir/.ref" ] || [[ "$(cat "$state_dir/.ref")" == pid:* ]]; }; then
        echo "$LATENCYNINJA_NETNS_REF" > "$state_dir/.ref"
    fi
}

# Function to list the runtime state files of interfaces shaped in containers and namespaces, as
# "<state file> <reference>" lines (host only; stale entries are skipped)
active_namespace_states() {
    local dir ref ns_file file interface
    for dir in "$state_root"/ns/*/; do
        [ -f "$dir.ref" ] || continue
        ref=$(cat "$dir.ref")
        ns_file=$(ref_to_nsfile "$ref")
        [ -n "$ns_file" ] || continue
        # Skip state left by a namespace that has since been replaced (e.g. a restarted container)
        [ "$(basename "$dir")" = "ns-$(stat -L -c %i "$ns_file")" ] || continue
        for file in "$dir"*.args; do
            [ -f "$file" ] || continue
            interface=$(basename "$file" .args)
            if nsenter --net="$ns_file" $ip_path link show "$(ifb_name_for "lni-" "$interface")" &>/dev/null || \
               nsenter --net="$ns_file" $ip_path link show "$(ifb_name_for "lne-" "$interface")" &>/dev/null; then
                echo "$file $ref"
            fi
        done
    done
}

# Function to forget the configuration of an interface
clear_runtime_state() {
    rm -f "$state_dir/$1.args"
}

# Function to list interfaces currently shaped by Latency Ninja
active_interfaces() {
    local file interface
    for file in "$state_dir"/*.args; do
        [ -f "$file" ] || continue
        interface=$(basename "$file" .args)
        # Ignore stale state, e.g. when the interface or its ifb devices were removed
        if $ip_path link show "$interface" &>/dev/null && \
           { $ip_path link show "$(ifb_name_for "lni-" "$interface")" &>/dev/null || \
             $ip_path link show "$(ifb_name_for "lne-" "$interface")" &>/dev/null; }; then
            echo "$interface"
        else
            rm -f "$file"
        fi
    done
}

# Function to print the tc configuration of all devices
dump_tc_rules() {
    local dev qdisc_output filter_output class_output
    for dev in $(list_network_devices); do
        qdisc_output=$($tc_path qdisc show dev "$dev" 2>/dev/null)
        filter_output=$($tc_path filter show dev "$dev" 2>/dev/null)
        class_output=$($tc_path class show dev "$dev" 2>/dev/null)

        # Skip devices with no tc configuration
        [ -z "$qdisc_output" ] && [ -z "$filter_output" ] && [ -z "$class_output" ] && continue

        echo "Device: $dev"
        [ -n "$qdisc_output" ] && { echo "Qdiscs:"; echo "$qdisc_output"; }
        [ -n "$filter_output" ] && { echo "Filters:"; echo "$filter_output"; }
        [ -n "$class_output" ] && { echo "Classes:"; echo "$class_output"; }
        echo ""
    done
}

# Function to write a restorable snapshot of the current Latency Ninja rules
write_snapshot() {
    local file="$1"
    local scope="${2:-all}"
    local interface

    {
        echo "# Latency Ninja snapshot"
        echo "# Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Restore with: $script_path --restore $file$(namespace_hint)"
        echo "[scope $scope]"
        in_namespace && echo "[namespace $LATENCYNINJA_NETNS_REF]"
        for interface in $(active_interfaces); do
            [ "$scope" != "all" ] && [ "$interface" != "$scope" ] && continue
            echo "[interface $interface]"
            cat "$state_dir/$interface.args"
            echo "[end]"
        done
        # Host snapshots of everything also include the rules of containers and namespaces
        if [ "$scope" = "all" ] && ! in_namespace; then
            local state_file ref
            while read -r state_file ref; do
                [ -n "$state_file" ] || continue
                echo "[interface $(basename "$state_file" .args) @$ref]"
                cat "$state_file"
                echo "[end]"
            done <<< "$(active_namespace_states)"
        fi
        echo "#"
        echo "# ### Previous TC Rules ###"
        echo "#"
        dump_tc_rules | sed 's/^/# /'
    } > "$file"
}

# Function to handle --save
save_snapshot() {
    local file="$1"
    local interface="$2"
    local target_dir

    target_dir=$(dirname "$file")
    [ -d "$target_dir" ] || die "Snapshot directory does not exist: $target_dir"
    [ -w "$target_dir" ] || die "Snapshot directory is not writable: $target_dir"

    write_snapshot "$file" "${interface:-all}" || die "Failed to write snapshot file: $file"

    local saved
    saved=$(grep '^\[interface ' "$file" | sed 's/^\[interface \(.*\)\]$/\1/; s/ @/@/' | tr '\n' ' ')
    echo "Snapshot saved to: $file"
    echo "Interfaces with rules: ${saved:-none}"
}

# Function to handle --restore: bring the rules back to the state recorded in a snapshot.
# Entries are "<interface>" (current namespace) or "<interface> @<reference>" (a container or
# namespace, in host snapshots).
restore_snapshot() {
    local file="$1"
    local only_interface="$2"
    local scope="all" current="" line entry interface ref failed=0 namespace=""
    declare -A saved=()

    [ -r "$file" ] || die "Snapshot file not found: $file"
    grep -q '^# Latency Ninja snapshot' "$file" || die "Not a Latency Ninja snapshot: $file"

    while IFS= read -r line; do
        case "$line" in
            '#'*|'') ;;
            '[scope '*']') scope="${line#\[scope }"; scope="${scope%\]}" ;;
            '[namespace '*']') namespace="${line#\[namespace }"; namespace="${namespace%\]}" ;;
            '[interface '*']') current="${line#\[interface }"; current="${current%\]}"; saved[$current]="" ;;
            '[end]') current="" ;;
            *) [ -n "$current" ] && saved[$current]+="$line"$'\n' ;;
        esac
    done < "$file"

    if [ "$namespace" != "${LATENCYNINJA_NETNS_REF:-}" ]; then
        die "This snapshot was taken in ${namespace:-the host namespace}, not ${LATENCYNINJA_NETNS_REF:-the host namespace}. Restore it with the same --netns, --pid or --container option."
    fi

    [ -n "$only_interface" ] && scope="$only_interface"
    echo "Restoring snapshot $file (scope: $scope)"

    # Roll back entries in scope that have rules now but had none in the snapshot
    local to_rollback=() state_file
    if [ "$scope" = "all" ]; then
        mapfile -t to_rollback < <(active_interfaces)
        if ! in_namespace; then
            while read -r state_file ref; do
                [ -n "$state_file" ] && to_rollback+=("$(basename "$state_file" .args) @$ref")
            done <<< "$(active_namespace_states)"
        fi
    else
        to_rollback=("$scope")
    fi
    local ref_options=()
    for entry in "${to_rollback[@]}"; do
        [ -n "$entry" ] || continue
        [ -n "${saved[$entry]+set}" ] && continue
        echo "  - $entry: no rules in snapshot, rolling back"
        interface="${entry% @*}"
        ref_options=()
        [[ "$entry" == *" @"* ]] && mapfile -t ref_options < <(ref_to_options "${entry#* @}")
        "$script_path" "${ref_options[@]}" --rollback --interface "$interface" --keep-persist </dev/null >/dev/null || failed=1
        [[ "$entry" != *" @"* ]] && is_persisted "$interface" && echo "    Note: $interface has persisted rules that will be re-applied at boot. Use --rollback to remove them."
    done

    # Re-apply the saved configuration of each entry in scope
    local args=() ns_file
    for entry in "${!saved[@]}"; do
        interface="${entry% @*}"
        ref_options=()
        if [[ "$entry" == *" @"* ]]; then
            # Containers and namespaces are only restored with the whole host snapshot
            [ "$scope" != "all" ] && continue
            ref="${entry#* @}"
            ns_file=$(ref_to_nsfile "$ref")
            if [ -z "$ns_file" ] || ! nsenter --net="$ns_file" $ip_path link show "$interface" &>/dev/null; then
                echo "  - $entry: $(ref_description "$ref") or its interface not found, skipping"
                failed=1
                continue
            fi
            mapfile -t ref_options < <(ref_to_options "$ref")
        else
            [ "$scope" != "all" ] && [ "$interface" != "$scope" ] && continue
            if ! $ip_path link show "$interface" &>/dev/null; then
                echo "  - $entry: interface not found, skipping"
                failed=1
                continue
            fi
        fi
        mapfile -t args <<< "${saved[$entry]%$'\n'}"
        if ! validate_saved_args "${args[@]}"; then
            echo "  - $entry: invalid saved arguments, skipping"
            failed=1
            continue
        fi
        echo "  - $entry: re-applying ${args[*]}"
        "$script_path" "${ref_options[@]}" "${args[@]}" </dev/null >/dev/null || { echo "    Failed to re-apply rules for $entry"; failed=1; }
    done

    [ "$failed" -eq 0 ] && echo "Snapshot restored." || die "Snapshot restored with errors."
}
