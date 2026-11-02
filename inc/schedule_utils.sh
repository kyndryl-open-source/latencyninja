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

# Timed rollbacks (--duration) use a transient systemd timer. When it fires, the interface is
# restored from the backup snapshot taken just before the rules were applied, so whatever was
# there before (nothing, or earlier rules) comes back. Applying new rules or rolling back an
# interface cancels its pending timer. Transient timers don't survive a reboot, which is why
# --duration can't be combined with --persist.
#
# --confirm-within is the same timed rollback used as a dead-man switch: the rules stay only if they are confirmed
# with --confirm before the time is up, which is what you want when a change might cut off your own access. A
# "<interface>.confirm" file marks the pending rollback of an interface as one that waits for a confirmation.

# Function to get the systemd unit name (without suffix) of an interface's timed rollback
rollback_unit_name() {
    echo "latencyninja-rollback-$(systemd-escape "${LATENCYNINJA_NETNS_KEY:+$LATENCYNINJA_NETNS_KEY-}$1")"
}

# Function to schedule the rollback of an interface
schedule_rollback() {
    local interface="$1"
    local seconds="$2"
    local backup_file="$3"
    local unit ns_args=()
    unit=$(rollback_unit_name "$interface")
    in_namespace && ns_args=("$LATENCYNINJA_NETNS_OPT" "$LATENCYNINJA_NETNS_VAL")
    # The timer records its rollback in the same audit log as the apply
    [ -n "$audit_log" ] && ns_args+=(--audit-log "$audit_log")

    systemctl reset-failed "$unit.service" "$unit.timer" &>/dev/null
    systemd-run --quiet --unit="$unit" --on-active="${seconds}s" --timer-property=AccuracySec=1s \
        --description="Latency Ninja timed rollback for $interface" \
        "$(command -v bash)" "$script_path" --timed-rollback "$backup_file" --interface "$interface" "${ns_args[@]}" \
        || die "Failed to schedule the rollback of $interface."

    mkdir -p "$state_dir" && chmod 700 "$state_dir"
    echo $(( $(date +%s) + seconds )) > "$state_dir/$interface.expires"
    echo "$backup_file" > "$state_dir/$interface.backup"  # kept by --clean while the rollback is pending
    if [ "$confirm_pending" -eq 1 ]; then
        touch "$state_dir/$interface.confirm"
        echo "Rollback of $interface scheduled at $(date -d "+${seconds} seconds" '+%Y-%m-%d %H:%M:%S') ($unit.timer) unless you confirm."
        echo "To keep the rules, run: sudo $0 --confirm --interface $interface$(namespace_hint)"
        echo "To roll back now, run: sudo $0 --rollback --interface $interface$(namespace_hint)"
    else
        echo "Rollback of $interface scheduled at $(date -d "+${seconds} seconds" '+%Y-%m-%d %H:%M:%S') ($unit.timer)."
        echo "To end earlier, run: sudo $0 --rollback --interface $interface$(namespace_hint)"
    fi
}

# Function to cancel the pending timed rollback of an interface
cancel_scheduled_rollback() {
    local interface="$1"
    [ -f "$state_dir/$interface.expires" ] || return 0
    command -v systemctl &>/dev/null && systemctl stop "$(rollback_unit_name "$interface").timer" &>/dev/null
    rm -f "$state_dir/$interface.expires" "$state_dir/$interface.backup" "$state_dir/$interface.confirm"
}

# Function to handle --confirm: keep the rules of an interface by cancelling the rollback --confirm-within scheduled
confirm_rules() {
    local interface="$1"
    if [ ! -f "$state_dir/$interface.confirm" ] || [ ! -f "$state_dir/$interface.expires" ]; then
        die "Nothing to confirm on $interface: no rollback is waiting for a confirmation (it may already have happened, see --query)."
    fi
    cancel_scheduled_rollback "$interface"
    audit_event confirm "interface=$interface"
    echo "Confirmed: the rules on $interface stay in place and will not be rolled back automatically."
}

# Function to list pending timed rollbacks with the time left
scheduled_rollbacks() {
    local file interface left list=""
    for file in "$state_dir"/*.expires; do
        [ -f "$file" ] || continue
        interface=$(basename "$file" .expires)
        left=$(( $(cat "$file") - $(date +%s) ))
        if [ "$left" -lt 0 ] || ! systemctl is-active -q "$(rollback_unit_name "$interface").timer" 2>/dev/null; then
            rm -f "$file" "${file%.expires}.backup" "${file%.expires}.confirm"
            continue
        fi
        list="${list:+$list, }$interface in $((left / 60))m $((left % 60))s"
        [ -f "${file%.expires}.confirm" ] && list="$list (unconfirmed)"
    done
    echo "${list:-none}"
}

# Function to handle --timed-rollback, called by the timer: restore the state from before the rules
run_timed_rollback() {
    local interface="$1"
    local backup_file="$2"

    local unconfirmed=""
    [ -f "$state_dir/$interface.confirm" ] && unconfirmed="yes"
    rm -f "$state_dir/$interface.expires" "$state_dir/$interface.backup" "$state_dir/$interface.confirm"
    if [ -f "$backup_file" ] && restore_snapshot "$backup_file" "$interface"; then
        echo "Timed rollback of $interface completed."
        audit_event timed_rollback "interface=$interface" "reason=$([ -n "$unconfirmed" ] && echo "not confirmed in time" || echo "duration ended")"
    else
        echo "Backup $backup_file unavailable, rolling back $interface."
        "$script_path" --rollback --interface "$interface" --keep-persist </dev/null
        audit_event timed_rollback "interface=$interface" "reason=$([ -n "$unconfirmed" ] && echo "not confirmed in time" || echo "duration ended")" "backup=unavailable"
    fi
}
