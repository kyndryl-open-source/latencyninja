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

# --check audits the state Latency Ninja leaves on the system and the parameters stored for it, and
# --clean (which checks first) repairs what can be repaired safely after asking for confirmation.
# Active rules, persisted rules and pending timed rollbacks are never touched. Checked:
#
#   - ifb devices (lni-*/lne-*) that no interface sends traffic through
#   - interfaces whose rules redirect to an ifb device that no longer exists
#   - saved rules, timed rollbacks and per-namespace state left behind by interfaces, containers and
#     namespaces that are gone, and timers without a recorded rollback
#   - persisted rules that would fail to apply (invalid values), and persistence units, udev rule or
#     namespace watcher left installed with nothing persisted
#   - backup files (--backup, default /tmp) older than backup_max_age_days that no pending rollback needs
#   - built-in and custom profile files with invalid values (reported only)
#
# On the host everything is checked; with --container, --netns or --pid only the state of that
# namespace (ifb devices, redirects, runtime state and persisted rules).

declare -g backup_max_age_days=30
declare -g -a finding_level=() finding_text=() finding_fn=() finding_arg=()
declare -g -A attempted_fixes=()  # findings --clean already tried to fix, so a fix that doesn't work isn't repeated

# Function to record a finding: level is fix (--clean repairs it with fn <arg>), manual (needs attention) or note
add_finding() {
    finding_level+=("$1")
    finding_text+=("$2")
    finding_fn+=("${3:-}")
    finding_arg+=("${4:-}")
}

# Function to count the findings of a level
count_findings() {
    local level
    local count=0
    for level in "${finding_level[@]}"; do
        [ "$level" = "$1" ] && count=$((count + 1))
    done
    echo "$count"
}

# Function to count the fixable findings --clean hasn't tried to fix yet
count_new_fixes() {
    local i count=0
    for i in "${!finding_level[@]}"; do
        [ "${finding_level[$i]}" = "fix" ] && [ -z "${attempted_fixes[${finding_text[$i]}]+set}" ] && count=$((count + 1))
    done
    echo "$count"
}

# ---------- checks ----------

# Function to find ifb devices that no interface sends traffic through
check_ifb_devices() {
    local dev devices claimed=" "
    devices=$(list_network_devices)
    for dev in $devices; do
        [[ "$dev" == lni-* || "$dev" == lne-* ]] && continue
        $tc_path qdisc show dev "$dev" 2>/dev/null | grep -q '^qdisc ingress ffff:' && claimed+="$(ifb_name_for "lni-" "$dev") "
        $tc_path qdisc show dev "$dev" 2>/dev/null | grep -q '^qdisc prio 1: root' && claimed+="$(ifb_name_for "lne-" "$dev") "
    done
    for dev in $devices; do
        [[ "$dev" == lni-* || "$dev" == lne-* ]] || continue
        $ip_path -d link show dev "$dev" 2>/dev/null | grep -qw ifb || continue
        [[ "$claimed" == *" $dev "* ]] && continue
        add_finding fix "ifb device $dev is not used by any interface" fix_orphan_ifb "$dev"
    done
}

# Function to find interfaces whose rules redirect traffic to an ifb device that is gone. tc prints
# the target of a redirect by name while the device exists and as * (or if<index>) once it is deleted,
# so all are looked at, and only when the ifb device Latency Ninja would use for the interface is missing.
check_dangling_redirects() {
    local dev kind prefix target expected
    for dev in $(list_network_devices); do
        [[ "$dev" == lni-* || "$dev" == lne-* ]] && continue
        for kind in "ingress lni-" "egress lne-"; do
            read -r kind prefix <<< "$kind"
            if [ "$kind" = "ingress" ]; then
                target=$($tc_path filter show dev "$dev" ingress 2>/dev/null | grep -oE 'Redirect to device [^) ]+' | awk 'NR == 1 {print $4}')
            else
                target=$($tc_path filter show dev "$dev" 2>/dev/null | grep -oE 'Redirect to device [^) ]+' | awk 'NR == 1 {print $4}')
            fi
            [ -n "$target" ] || continue
            expected=$(ifb_name_for "$prefix" "$dev")
            [[ "$target" == "$expected" || "$target" == "*" || "$target" =~ ^if[0-9]+$ ]] || continue
            $ip_path link show dev "$expected" &>/dev/null && continue
            add_finding fix "Rules on $dev redirect $kind traffic to $expected, which no longer exists" fix_reset_interface "$dev"
            break
        done
    done
}

# Function to find stale runtime state in the current namespace: saved rules of interfaces without rules,
# expired timed rollbacks and leftover backup references
check_runtime_state() {
    local file interface left
    for file in "$state_dir"/*.args; do
        [ -f "$file" ] || continue
        interface=$(basename "$file" .args)
        if ! $ip_path link show "$interface" &>/dev/null; then
            add_finding fix "Saved rules of $interface: the interface no longer exists" fix_stale_file "$file"
        elif ! $ip_path link show "$(ifb_name_for "lni-" "$interface")" &>/dev/null && \
             ! $ip_path link show "$(ifb_name_for "lne-" "$interface")" &>/dev/null; then
            add_finding fix "Saved rules of $interface: no rules are applied to it anymore" fix_stale_file "$file"
        fi
    done
    for file in "$state_dir"/*.expires; do
        [ -f "$file" ] || continue
        interface=$(basename "$file" .expires)
        left=$(( $(cat "$file" 2>/dev/null || echo 0) - $(date +%s) ))
        if [ "$left" -lt -30 ] || { command -v systemctl &>/dev/null && ! systemctl is-active -q "$(rollback_unit_name "$interface").timer" 2>/dev/null; }; then
            add_finding fix "Timed rollback of $interface: it has expired or its timer is gone" fix_stale_schedule "$file"
        fi
    done
    for file in "$state_dir"/*.backup; do
        [ -f "$file" ] || continue
        [ -f "${file%.backup}.expires" ] || add_finding fix "Backup reference $(basename "$file"): no timed rollback is pending" fix_stale_file "$file"
    done
}

# Function to find the state of containers and namespaces that are gone or were replaced (host only)
check_namespace_state() {
    local dir key ref="" ns_file description
    for dir in "$state_root"/ns/*/; do
        [ -d "$dir" ] || continue
        key=$(basename "$dir")
        ref=""
        [ -f "${dir}.ref" ] && ref=$(cat "${dir}.ref")
        ns_file=""
        description="an unknown namespace"
        if [ -n "$ref" ]; then
            ns_file=$(ref_to_nsfile "$ref")
            description=$(ref_description "$ref")
        fi
        if [ -z "$ns_file" ]; then
            add_finding fix "State of $description ($key): it no longer exists" fix_stale_dir "$dir"
        elif [ "$key" != "ns-$(stat -L -c %i "$ns_file")" ]; then
            add_finding fix "State of $description ($key): it was re-created since" fix_stale_dir "$dir"
        fi
    done
}

# Function to find timers of timed rollbacks that no recorded rollback refers to, and failed Latency Ninja units (host only)
check_timers() {
    command -v systemctl &>/dev/null && [ -d /run/systemd/system ] || return 0
    local file interface key unit expected=" "
    for file in "$state_root"/*.expires; do
        [ -f "$file" ] || continue
        expected+="$(rollback_unit_name "$(basename "$file" .expires)").timer "
    done
    for file in "$state_root"/ns/*/*.expires; do
        [ -f "$file" ] || continue
        key=$(basename "$(dirname "$file")")
        expected+="latencyninja-rollback-$(systemd-escape "$key-$(basename "$file" .expires)").timer "
    done
    while read -r unit; do
        [[ "$unit" == latencyninja-rollback-*.timer ]] || continue
        [[ "$expected" == *" $unit "* ]] && continue
        add_finding fix "Timer $unit has no timed rollback recorded" fix_timer "$unit"
    done < <(systemctl list-units --all --plain --no-legend 'latencyninja-rollback-*.timer' 2>/dev/null | awk '{print $1}')
    while read -r unit; do
        [ -n "$unit" ] && add_finding manual "Unit $unit failed, see: journalctl -u $unit"
    done < <(systemctl list-units --failed --plain --no-legend 'latencyninja@*' 'latencyninja-namespaces*' 2>/dev/null | awk '{print $1}')
}

# Function to list the persisted rule files in the current scope: those of the host, containers and
# namespaces on the host, or only the ones of the current namespace
persist_files_in_scope() {
    local file
    if in_namespace; then
        file=$(persist_file x) || return 0
        for file in "$(dirname "$file")"/*.args; do
            [ -f "$file" ] && echo "$file"
        done
    else
        for file in "$persist_dir"/*.args; do
            [ -f "$file" ] && echo "$file"
        done
        namespace_persist_files
    fi
}

# Function to describe a persisted rules file ("eth0" or "eth0 in container web")
persist_file_label() {
    local file="$1" relative="${1#"$persist_dir"/}" rest
    if [[ "$relative" == */*/*.args ]]; then
        rest="${relative#*/}"
        echo "$(basename "$file" .args) in ${relative%%/*} ${rest%%/*}"
    else
        basename "$file" .args
    fi
}

# Function to print why saved or persisted arguments (one option or value per argument) can't be applied; nothing if they can
saved_args_error() {
    local args=("$@") i opt value name kind error has_interface=0 has_latency=0 has_reorder=0
    [ "${#args[@]}" -gt 0 ] || { echo "it is empty"; return; }
    validate_saved_args "${args[@]}" || { echo "it contains options that don't apply rules"; return; }
    [ $(( ${#args[@]} % 2 )) -eq 0 ] || { echo "an option has no value"; return; }
    for ((i = 0; i < ${#args[@]}; i += 2)); do
        opt="${args[$i]}"
        value="${args[$((i + 1))]}"
        case "$opt" in
            --interface) has_interface=1 ;;
            --latency|--jitter|--packet_loss|--duplicate|--corrupt|--reorder)
                name="${opt#--}"
                [ "$name" = "latency" ] && has_latency=1
                [ "$name" = "reorder" ] && has_reorder=1
                error=$(declare -g "$name=$value"; check_numeric "$name" 2>&1) || { echo "${error#Error: }"; return; } ;;
            --rate)
                error=$(validate_rate "$value" 2>&1) || { echo "${error#Error: }"; return; } ;;
            --direction)
                [[ "$value" =~ ^(egress|ingress|both)$ ]] || { echo "invalid direction $value"; return; } ;;
            --src_ip|--dst_ip)
                kind="${opt#--}"
                kind="${kind%_ip}"
                error=$(add_ip_entries "$kind" "$value"; normalize_ip_list "$kind" 2>&1) || { echo "${error#Error: }"; return; } ;;
        esac
    done
    [ "$has_interface" -eq 1 ] || { echo "it has no interface"; return; }
    [ "$has_reorder" -eq 0 ] || [ "$has_latency" -eq 1 ] || echo "reorder can only be used with latency"
}

# Function to check persisted rules and the persistence machinery installed for them
check_persistence() {
    local file label args=() message target ns_files host_files
    while read -r file; do
        [ -n "$file" ] || continue
        label=$(persist_file_label "$file")
        mapfile -t args < "$file"
        message=$(saved_args_error "${args[@]}")
        if [ -n "$message" ]; then
            add_finding fix "Persisted rules for $label cannot be applied: ${message%%$'\n'*}" fix_persist_file "$file"
        elif [[ "$file" == "$persist_dir"/*/*/*.args ]]; then
            target="${file#"$persist_dir"/}"
            target="${target%/*}"
            [ -n "$(ref_to_nsfile "${target%%/*}:${target#*/}")" ] || add_finding note "Persisted rules for $label: it isn't running now, they apply when it starts"
        elif ! in_namespace && ! $ip_path link show "$(basename "$file" .args)" &>/dev/null; then
            add_finding note "Persisted rules for $label: the interface doesn't exist now, they apply when it appears"
        fi
    done < <(persist_files_in_scope)

    in_namespace && return 0
    host_files=$(for file in "$persist_dir"/*.args; do [ -f "$file" ] && echo "$file"; done)
    ns_files=$(namespace_persist_files)
    if [ -z "$host_files" ] && { [ -e "$unit_file" ] || [ -e "$udev_rule_file" ]; }; then
        add_finding fix "Persistence is installed ($unit_file, $udev_rule_file) but no interface is persisted" fix_persist_leftovers
    fi
    if [ -z "$ns_files" ] && [ -e "$watcher_unit_file" ]; then
        add_finding fix "The namespace watcher ($(basename "$watcher_unit_file")) is installed but no container or namespace is persisted" fix_watcher_leftover
    fi
}

# Function to print the backup files that pending timed rollbacks still need
protected_backups() {
    local file
    for file in "$state_root"/*.backup "$state_root"/ns/*/*.backup; do
        [ -f "$file" ] && cat "$file"
    done
}

# Function to print the backup files in a directory that are old enough to be removed
old_backup_files() {
    find "$1" -maxdepth 1 -type f -name 'latencyninja_tc_backup_*' -mtime "+$backup_max_age_days" 2>/dev/null | grep -vxFf <(protected_backups)
}

# Function to find old backup files (host only)
check_old_backups() {
    local dir="${backup_dir:-/tmp}" count
    [ -d "$dir" ] || return 0
    count=$(old_backup_files "$dir" | grep -c .)
    [ "$count" -gt 0 ] && add_finding fix "$count backup file(s) in $dir older than $backup_max_age_days days" fix_old_backups "$dir"
}

# Function to print what is wrong with a profile file, if anything
profile_error() {
    local file="$1" unknown key value error
    $jq_path -e 'type == "object"' "$file" &>/dev/null || { echo "it is not a JSON object"; return; }
    unknown=$($jq_path -r 'keys - ["description", "latency", "jitter", "packet_loss", "duplicate", "corrupt", "reorder", "rate"] | join(", ")' "$file")
    [ -n "$unknown" ] && { echo "unknown key(s): $unknown"; return; }
    for key in latency jitter packet_loss duplicate corrupt reorder; do
        value=$($jq_path -r --arg k "$key" '.[$k] // empty' "$file")
        [ -n "$value" ] || continue
        error=$(declare -g "$key=$value"; check_numeric "$key" 2>&1) || { echo "${error#Error: }"; return; }
    done
    value=$($jq_path -r '.rate // empty' "$file")
    if [ -n "$value" ]; then
        error=$(validate_rate "$value" 2>&1) || echo "${error#Error: }"
    fi
}

# Function to check the built-in and custom profiles (host only)
check_profiles() {
    local file error
    for file in "$user_profiles_dir"/*.json "$profiles_dir"/*.json; do
        [ -f "$file" ] || continue
        error=$(profile_error "$file")
        [ -n "$error" ] && add_finding manual "Profile $file is not valid: $error"
    done
}

# Function to run all checks that apply to the current scope
run_checks() {
    finding_level=(); finding_text=(); finding_fn=(); finding_arg=()
    check_ifb_devices
    check_dangling_redirects
    check_runtime_state
    check_persistence
    if ! in_namespace; then
        check_namespace_state
        check_timers
        check_old_backups
        check_profiles
    fi
}

# ---------- fixes ----------

fix_orphan_ifb() {
    $ip_path link delete dev "$1"
}

# Remove the Latency Ninja rules of an interface the same way --rollback does (persisted rules are kept)
fix_reset_interface() {
    local interface="$1"
    eth_interface="$interface"
    set_ifb_interfaces "$interface"
    rollback_required=1
    rollback_done=0
    rollback_everything silent
    cancel_scheduled_rollback "$interface"
    clear_runtime_state "$interface"
}

fix_stale_file() {
    rm -f "$1"
}

fix_stale_schedule() {
    rm -f "$1" "${1%.expires}.backup"
}

fix_stale_dir() {
    local dir="${1%/}" file
    [[ "$dir" == "$state_root"/ns/ns-* ]] || return 1
    if command -v systemctl &>/dev/null && command -v systemd-escape &>/dev/null; then
        for file in "$dir"/*.expires; do
            [ -f "$file" ] && systemctl stop "latencyninja-rollback-$(systemd-escape "$(basename "$dir")-$(basename "$file" .expires)").timer" &>/dev/null
        done
    fi
    rm -rf -- "$dir"
}

fix_timer() {
    systemctl stop "$1" &>/dev/null
    systemctl reset-failed "$1" "${1%.timer}.service" &>/dev/null
    return 0
}

fix_persist_file() {
    local file="$1"
    rm -f "$file" || return 1
    if [[ "$file" == "$persist_dir"/*/*/*.args ]]; then
        rmdir "$(dirname "$file")" "$(dirname "$(dirname "$file")")" 2>/dev/null
    elif command -v systemctl &>/dev/null && command -v systemd-escape &>/dev/null; then
        systemctl stop "$(persist_unit_name "$(basename "$file" .args)")" &>/dev/null
    fi
    return 0
}

fix_persist_leftovers() {
    rm -f "$unit_file" "$udev_rule_file"
    systemctl daemon-reload &>/dev/null
    udevadm control --reload &>/dev/null
    return 0
}

fix_watcher_leftover() {
    systemctl disable --now "$(basename "$watcher_unit_file")" &>/dev/null
    rm -f "$watcher_unit_file"
    systemctl daemon-reload &>/dev/null
    return 0
}

fix_old_backups() {
    local file
    while read -r file; do
        rm -f "$file"
    done < <(old_backup_files "$1")
    return 0
}

# ---------- commands ----------

# Function to print the findings; with "new" only the fixable ones --clean hasn't tried yet, with "open" the
# ones that still need action
print_findings() {
    local i marker
    for i in "${!finding_level[@]}"; do
        case "${finding_level[$i]}" in
            fix) marker="[clean]" ;;
            manual) marker="[check]" ;;
            *) marker="[info]" ;;
        esac
        case "$1" in
            new) [ "${finding_level[$i]}" = "fix" ] && [ -z "${attempted_fixes[${finding_text[$i]}]+set}" ] || continue ;;
            open) [ "${finding_level[$i]}" = "note" ] && continue ;;
        esac
        printf '  %-8s %s\n' "$marker" "${finding_text[$i]}"
    done
}

# Function to fix the findings that can be fixed and weren't tried yet, after confirmation
fix_findings() {
    local i answer
    if [ "$assume_yes" -ne 1 ]; then
        [ -t 0 ] || die "Not running in a terminal, use --yes to clean without confirmation."
        echo
        echo "Clean the [clean] items above? (yes/no)"
        read -r answer
        [ "$answer" = "yes" ] || { echo "Cleaning cancelled."; return 1; }
    fi
    echo
    for i in "${!finding_level[@]}"; do
        [ "${finding_level[$i]}" = "fix" ] && [ -z "${attempted_fixes[${finding_text[$i]}]+set}" ] || continue
        attempted_fixes[${finding_text[$i]}]=1
        if "${finding_fn[$i]}" "${finding_arg[$i]}"; then
            echo "  cleaned: ${finding_text[$i]}"
        else
            echo "  FAILED:  ${finding_text[$i]}"
        fi
    done
}

# Function to handle --check and --clean
run_check_clean() {
    local round fixable fixed=0 problems

    attempted_fixes=()
    echo
    echo "Checking ${LATENCYNINJA_NETNS_DESC:-the host}..."
    echo
    for round in 1 2 3; do
        fixed=0
        run_checks
        fixable=$(count_new_fixes)
        if [ "$round" -eq 1 ]; then
            if [ "${#finding_level[@]}" -eq 0 ]; then
                echo "No problems found."
                echo
                return 0
            fi
            print_findings
        elif [ "$fixable" -gt 0 ]; then
            # Cleaning can uncover more (e.g. persistence units once the last persisted file is removed)
            echo
            echo "Found more after cleaning:"
            print_findings new
        fi
        [ "$clean_mode" -eq 1 ] && [ "$fixable" -gt 0 ] || break
        fix_findings || return 1
        fixed=1
    done
    [ "$fixed" -eq 1 ] && run_checks

    problems=$(( $(count_findings fix) + $(count_findings manual) ))
    echo
    if [ "$problems" -eq 0 ]; then
        [ "$clean_mode" -eq 1 ] && echo "Everything is clean." || echo "No problems found, the items above are for information."
    elif [ "$clean_mode" -eq 1 ]; then
        echo "$problems item(s) left that need attention:"
        print_findings open
    else
        fixable=$(count_findings fix)
        echo "Found $problems problem(s)$([ "$fixable" -gt 0 ] && echo ", $fixable can be fixed with: sudo $0 --clean$(namespace_hint)")."
    fi
    echo
    [ "$problems" -eq 0 ]
}
