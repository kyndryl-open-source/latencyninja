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

# Namespace targeting (--netns, --pid, --container): Latency Ninja re-runs itself inside the target
# network namespace with nsenter, so every ip/tc command (including the ifb devices) applies there.
# The environment variables below tell the re-executed process (and anything it starts, such as
# snapshot restores) which namespace it is in:
#
#   LATENCYNINJA_NETNS_KEY   unique key used to keep state per namespace (e.g. container-3f2a9c1b7d4e)
#   LATENCYNINJA_NETNS_DESC  human readable description (e.g. "docker container web")
#   LATENCYNINJA_NETNS_OPT   the option used (--netns, --pid or --container)
#   LATENCYNINJA_NETNS_VAL   its value, so timed rollbacks and hints can re-enter the same namespace

# Function to resolve a running Docker or Podman container to its PID and ID
resolve_container() {
    local name="$1" runtime output running

    for runtime in docker podman; do
        command -v "$runtime" &>/dev/null || continue
        output=$("$runtime" inspect --type container -f '{{.State.Pid}} {{.Id}} {{.State.Running}}' "$name" 2>/dev/null) || continue
        read -r container_pid container_id running <<< "$output"
        if [ "$running" != "true" ] || ! [[ "$container_pid" =~ ^[0-9]+$ ]] || [ "$container_pid" -eq 0 ]; then
            die "Container $name is not running."
        fi
        container_runtime="$runtime"
        return 0
    done
    die "Container not found: $name (looked for it with: docker, podman)."
}

# Function to re-run Latency Ninja inside the requested network namespace, if any
enter_namespace_if_requested() {
    # Already running inside the namespace
    [ -n "$LATENCYNINJA_NETNS_KEY" ] && return 0

    local args=() ns_opt="" ns_val=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --netns|--pid|--container)
                [ -n "$ns_opt" ] && die "Only one of --netns, --pid or --container can be used."
                if [ -z "$2" ] || [[ "$2" == -* ]]; then
                    die "The $1 option requires an argument."
                fi
                ns_opt="$1"; ns_val="$2"; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    [ -z "$ns_opt" ] && return 0

    check_root
    command -v nsenter &>/dev/null || die "The 'nsenter' command (util-linux) is required for $ns_opt."

    local ns_file key desc
    case "$ns_opt" in
        --netns)
            if ! [[ "$ns_val" =~ ^[A-Za-z0-9._-]+$ ]] || [ ! -e "/run/netns/$ns_val" ]; then
                die "Network namespace not found: $ns_val. See 'ip netns list'."
            fi
            ns_file="/run/netns/$ns_val"; key="netns-$ns_val"; desc="network namespace $ns_val" ;;
        --pid)
            if ! [[ "$ns_val" =~ ^[0-9]+$ ]] || [ ! -e "/proc/$ns_val/ns/net" ]; then
                die "Process not found: $ns_val."
            fi
            ns_file="/proc/$ns_val/ns/net"; key="pid-$ns_val"; desc="process $ns_val" ;;
        --container)
            resolve_container "$ns_val"
            ns_file="/proc/$container_pid/ns/net"; key="container-${container_id:0:12}"; desc="$container_runtime container $ns_val" ;;
    esac

    [ "${#args[@]}" -eq 0 ] && usage

    export LATENCYNINJA_NETNS_KEY="$key" LATENCYNINJA_NETNS_DESC="$desc" LATENCYNINJA_NETNS_OPT="$ns_opt" LATENCYNINJA_NETNS_VAL="$ns_val"
    exec nsenter --net="$ns_file" bash "$script_path" "${args[@]}"
}

# Function to check if running inside a target namespace
in_namespace() {
    [ -n "$LATENCYNINJA_NETNS_KEY" ]
}

# Function to print the namespace option to append to suggested commands (empty on the host)
namespace_hint() {
    in_namespace && printf ' %s %s' "$LATENCYNINJA_NETNS_OPT" "$LATENCYNINJA_NETNS_VAL"
}
