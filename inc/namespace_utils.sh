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
#   LATENCYNINJA_NETNS_KEY   key of the namespace itself (ns-<inode>), used to keep runtime state and timers
#                            per namespace however it was targeted (e.g. --pid of a process in a container)
#   LATENCYNINJA_NETNS_DESC  human readable description (e.g. "docker container web")
#   LATENCYNINJA_NETNS_OPT   the option used (--netns, --pid or --container)
#   LATENCYNINJA_NETNS_VAL   its value as given, used in suggested commands
#   LATENCYNINJA_NETNS_REF   stable reference used to re-enter the namespace later (snapshots,
#                            persistence, timed rollbacks): container:<name>, netns:<name> or pid:<pid>.
#                            Containers are referenced by name, which survives restarts and re-creation.

# Function to resolve a running Docker or Podman container to its PID and ID
resolve_container() {
    local name="$1" runtime output running

    for runtime in docker podman; do
        command -v "$runtime" &>/dev/null || continue
        output=$("$runtime" inspect --type container -f '{{.State.Pid}} {{.Id}} {{.State.Running}} {{.Name}}' "$name" 2>/dev/null) || continue
        read -r container_pid container_id running container_name <<< "$output"
        container_name="${container_name#/}"  # Docker prefixes names with a slash
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
    # A namespace can also come from the JSON file (die() inside $(...) only exits the subshell)
    local json_target
    json_target=$(json_namespace_target "${args[@]}") || { echo "$json_target"; exit 1; }
    if [ -z "$ns_opt" ]; then
        read -r ns_opt ns_val <<< "$json_target"
    elif [ -n "$json_target" ]; then
        die "The namespace is given both on the command line and in the JSON file. Use only one."
    fi
    [ -z "$ns_opt" ] && return 0

    check_root
    command -v nsenter &>/dev/null || die "The 'nsenter' command (util-linux) is required for $ns_opt."

    local ns_file key desc ref
    case "$ns_opt" in
        --netns)
            if ! [[ "$ns_val" =~ ^[A-Za-z0-9._-]+$ ]] || [ ! -e "/run/netns/$ns_val" ]; then
                die "Network namespace not found: $ns_val. See 'ip netns list'."
            fi
            ns_file="/run/netns/$ns_val"; desc="network namespace $ns_val"; ref="netns:$ns_val" ;;
        --pid)
            if ! [[ "$ns_val" =~ ^[0-9]+$ ]] || [ ! -e "/proc/$ns_val/ns/net" ]; then
                die "Process not found: $ns_val."
            fi
            ns_file="/proc/$ns_val/ns/net"; desc="process $ns_val"; ref="pid:$ns_val" ;;
        --container)
            resolve_container "$ns_val"
            ns_file="/proc/$container_pid/ns/net"; desc="$container_runtime container $container_name"; ref="container:$container_name" ;;
    esac

    # A target in the host's own namespace (e.g. --pid of a host process) is the host
    if [ "$(stat -L -c %i "$ns_file")" = "$(stat -L -c %i /proc/self/ns/net)" ]; then
        echo "Note: $desc uses the host network namespace, applying to the host."
        exec bash "$script_path" "${args[@]}"
    fi
    key="ns-$(stat -L -c %i "$ns_file")"

    [ "${#args[@]}" -eq 0 ] && usage

    export LATENCYNINJA_NETNS_KEY="$key" LATENCYNINJA_NETNS_DESC="$desc" LATENCYNINJA_NETNS_OPT="$ns_opt" LATENCYNINJA_NETNS_VAL="$ns_val" LATENCYNINJA_NETNS_REF="$ref"
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

# Function to print the namespace target ("--container name", "--netns name" or "--pid pid") set in
# the JSON file passed with --json, if any. Exits with an error if more than one is set.
json_namespace_target() {
    local json_arg="" jq_cmd targets
    while [ $# -gt 0 ]; do
        [ "$1" = "--json" ] && { json_arg="$2"; break; }
        shift
    done
    [ -n "$json_arg" ] && [ -f "$json_arg" ] || return 0
    jq_cmd=$(command -v jq) || return 0
    targets=$("$jq_cmd" -r 'if type == "object" then [(if .container then "--container \(.container)" else empty end),
        (if .netns then "--netns \(.netns)" else empty end), (if .pid then "--pid \(.pid)" else empty end)] | .[] else empty end' "$json_arg" 2>/dev/null)
    [ "$(grep -c . <<< "$targets")" -gt 1 ] && die "Only one of container, netns or pid can be set in the JSON file."
    echo "$targets"
}

# Function to print the options that enter the namespace of a reference (container:<name>, netns:<name>, pid:<pid>)
ref_to_options() {
    local ref="$1"
    printf -- '--%s\n%s\n' "${ref%%:*}" "${ref#*:}"
}

# Function to print the network namespace file of a reference, or fail if the target doesn't exist
ref_to_nsfile() {
    local ref="$1" type="${1%%:*}" name="${1#*:}" runtime output pid running
    case "$type" in
        netns) [ -e "/run/netns/$name" ] && echo "/run/netns/$name" ;;
        pid) [ -e "/proc/$name/ns/net" ] && echo "/proc/$name/ns/net" ;;
        container)
            for runtime in docker podman; do
                command -v "$runtime" &>/dev/null || continue
                output=$("$runtime" inspect --type container -f '{{.State.Pid}} {{.State.Running}}' "$name" 2>/dev/null) || continue
                read -r pid running <<< "$output"
                [ "$running" = "true" ] && [ "$pid" -gt 0 ] && echo "/proc/$pid/ns/net"
                return
            done ;;
    esac
}

# Function to describe a reference for display ("container web", "netns blue", "pid 1234")
ref_description() {
    echo "${1%%:*} ${1#*:}"
}
