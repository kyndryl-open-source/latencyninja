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

# The audit log records every change Latency Ninja makes to the network (rules applied, rolled back, restored,
# confirmed, removed by a timer or at boot), who made it and from where, as one JSON object per line
# (default /var/log/latencyninja/audit.log, or --audit-log). It is separate from the execution log (--logging),
# which is meant to be read by people. Read it with jq, for example:
#
#   jq -r '[.ts, .actor, .event, .interface] | @tsv' /var/log/latencyninja/audit.log

# Function to check that the audit log can be written, so a bad --audit-log path is reported before rules are applied.
# Nothing is created: a missing default directory is only checked for being creatable.
check_audit_log() {
    local file="${audit_log:-$default_audit_log}" dir
    dir=$(dirname "$file")
    if [ ! -d "$dir" ]; then
        [ "$file" = "$default_audit_log" ] && [ -w "$(dirname "$dir")" ] && return 0
        die "Audit log directory does not exist: $dir"
    fi
    if [ -f "$file" ] && [ ! -w "$file" ]; then
        die "Audit log is not writable: $file"
    elif [ ! -f "$file" ] && [ ! -w "$dir" ]; then
        die "Audit log directory is not writable: $dir"
    fi
}

# Function to print who is running Latency Ninja: the user behind sudo, or the actor set by a timer or the boot unit
audit_actor_name() {
    [ -n "$audit_actor" ] && { echo "$audit_actor"; return; }
    echo "${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
}

# Function to record an event in the audit log. The details are key=value arguments; empty values are left out.
# A problem writing the log is a warning, never a reason to stop: rolling back must always work.
audit_event() {
    local event="$1" file="${audit_log:-$default_audit_log}" detail line source
    local jq_args=()
    shift

    source="${SSH_CONNECTION%% *}"
    [ -z "$source" ] && source="$(tty 2>/dev/null | grep -v 'not a tty')"
    jq_args=(--arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg event "$event" --arg actor "$(audit_actor_name)"
        --arg host "$(hostname 2>/dev/null)" --arg source "$source" --arg namespace "${LATENCYNINJA_NETNS_DESC:-}"
        --arg command "$audit_command" --arg version "$current_version")
    for detail in "$@"; do
        [[ "$detail" == *=* ]] && [ -n "${detail#*=}" ] && jq_args+=(--arg "${detail%%=*}" "${detail#*=}")
    done

    line=$($jq_path -nc "${jq_args[@]}" '$ARGS.named | with_entries(select(.value != ""))' 2>/dev/null) || return 0
    if ! { mkdir -p "$(dirname "$file")" && ( umask 027; echo "$line" >> "$file" ); } 2>/dev/null; then
        echo "Warning: could not write to the audit log $file." >&2
    fi
}

# Function to set audit_details to the key=value details of the rules being applied, for audit_event
audit_rule_details() {
    audit_details=("interface=$eth_interface" "direction=$direction" "src_ip=$src_ip_arg" "dst_ip=$dst_ip_arg"
        "latency=$latency" "jitter=$jitter" "packet_loss=$packet_loss" "duplicate=$duplicate" "corrupt=$corrupt"
        "reorder=$reorder" "rate=$rate" "protocol=$protocol" "mtu=$mtu" "profile=$profile")
    if [ "$confirm_pending" -eq 1 ]; then
        audit_details+=("confirm_within=$duration")
    else
        audit_details+=("duration=$duration")
    fi
    [ "$persist" -eq 1 ] && audit_details+=("persist=yes")
    return 0
}
