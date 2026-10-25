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

# Persistence uses a udev rule that (re)starts a systemd oneshot unit every time a persisted interface
# appears: at boot (coldplug) and whenever the interface is re-created (e.g. wg-quick down/up, a bond
# re-created by NetworkManager). udev "add" events are used rather than device unit dependencies because
# systemd can miss a quick remove/add of the same device. Rules survive a plain link down/up on their
# own, since qdiscs stay attached to the device.
#
# udev doesn't see interfaces inside other network namespaces, so rules persisted for a container or
# a named namespace are re-applied by a watcher service (--watch-namespaces) instead. It checks every
# few seconds and re-applies the rules when the namespace or the interface is new (container restart,
# namespace or interface re-created), like udev does on the host, so rules deliberately removed or
# changed in a running container aren't overridden. Processes (--pid) don't survive restarts, so
# their rules can't be persisted.
# Function to get the systemd unit name for an interface
persist_unit_name() {
    echo "latencyninja@$(systemd-escape "$1").service"
}

# Function to print the file holding the persisted rules of an interface in the current namespace:
# $persist_dir/<interface>.args on the host, $persist_dir/<container|netns>/<name>/<interface>.args
# in a container or named namespace. Fails for processes, which can't have persisted rules.
persist_file() {
    local interface="$1"
    if ! in_namespace; then
        echo "$persist_dir/$interface.args"
    elif [[ "$LATENCYNINJA_NETNS_REF" == container:* || "$LATENCYNINJA_NETNS_REF" == netns:* ]]; then
        echo "$persist_dir/${LATENCYNINJA_NETNS_REF%%:*}/${LATENCYNINJA_NETNS_REF#*:}/$interface.args"
    else
        return 1
    fi
}

# Function to check if an interface has persisted rules
is_persisted() {
    local file
    file=$(persist_file "$1") && [ -f "$file" ]
}

# Function to check that persistence can be used on this system and target
check_persist_supported() {
    if ! command -v systemctl &>/dev/null || [ ! -d /run/systemd/system ]; then
        die "The --persist option requires systemd."
    fi
    if in_namespace && [[ "$LATENCYNINJA_NETNS_REF" == pid:* ]]; then
        die "The --persist option isn't supported with --pid: processes don't survive restarts. Use --container or --netns."
    fi
}

# Function to install and start the watcher that re-applies persisted rules in containers and namespaces
install_namespace_watcher() {
    cat > "$watcher_unit_file" <<EOF || return 1
# Installed by Latency Ninja ($script_path --persist)
[Unit]
Description=Latency Ninja persisted network perturbations for containers and network namespaces
After=network.target docker.service podman.service
RequiresMountsFor=$script_dir

[Service]
Type=simple
ExecStart=$(command -v bash) "$script_path" --watch-namespaces
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$(basename "$watcher_unit_file")" &>/dev/null
}

# Function to list the persisted rule files of all containers and named namespaces
namespace_persist_files() {
    local file
    for file in "$persist_dir"/container/*/*.args "$persist_dir"/netns/*/*.args; do
        [ -f "$file" ] && echo "$file"
    done
}

# Function to install the systemd unit and udev rule pointing at this copy of Latency Ninja.
# The script is run through bash because SELinux (Fedora/RHEL) denies systemd executing scripts
# that live in home directories or network mounts.
install_persist_unit() {
    cat > "$unit_file" <<EOF || return 1
# Installed by Latency Ninja ($script_path --persist)
[Unit]
Description=Latency Ninja persisted network perturbations for %I
RequiresMountsFor=$script_dir

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$(command -v bash) "$script_path" --apply-persisted %I
TimeoutStartSec=90
EOF

    # In udev rules "$$" is a literal "$", so the shell gets $(systemd-escape <interface>)
    cat > "$udev_rule_file" <<EOF || return 1
# Installed by Latency Ninja ($script_path --persist)
ACTION=="add", SUBSYSTEM=="net", TEST=="$persist_dir/%k.args", RUN+="/bin/sh -c '$(command -v systemctl) --no-block restart latencyninja@\$\$($(command -v systemd-escape) %k).service'"
EOF
}

# Function to persist the applied configuration of an interface
persist_rules() {
    local interface="$1"
    local file unit
    file=$(persist_file "$interface") || die "Rules can't be persisted in $LATENCYNINJA_NETNS_DESC."

    mkdir -p "$(dirname "$file")" && chmod 700 "$persist_dir" "$(dirname "$file")"
    build_canonical_args > "$file" || die "Failed to save persisted rules for $interface."

    if in_namespace; then
        install_namespace_watcher || die "Failed to install $watcher_unit_file."
        echo "Persisted: rules for $interface in $LATENCYNINJA_NETNS_DESC will be re-applied when it restarts or the interface is re-created ($(basename "$watcher_unit_file"))."
    else
        unit=$(persist_unit_name "$interface")
        install_persist_unit || die "Failed to install $unit_file."
        systemctl daemon-reload
        udevadm control --reload &>/dev/null
        echo "Persisted: rules for $interface will be re-applied at boot and when the interface is re-created ($unit)."
    fi
}

# Function to remove the persisted configuration of an interface
unpersist_rules() {
    local interface="$1"
    local file
    is_persisted "$interface" || return 0
    file=$(persist_file "$interface")

    rm -f "$file"
    if in_namespace; then
        rmdir "$(dirname "$file")" 2>/dev/null
        # Stop the watcher when no container or namespace has persisted rules anymore
        [ -z "$(namespace_persist_files)" ] && systemctl disable --now "$(basename "$watcher_unit_file")" &>/dev/null
        echo "Removed persisted rules for $interface in $LATENCYNINJA_NETNS_DESC."
    else
        systemctl stop "$(persist_unit_name "$interface")" &>/dev/null
        echo "Removed persisted rules for $interface."
    fi
}

# Function to list interfaces with persisted rules. On the host, rules of containers and namespaces
# are listed as <interface>@<container|netns>:<name>; inside one, only its own interfaces are listed.
persisted_interfaces() {
    local file name
    if in_namespace; then
        file=$(persist_file "x") || return 0
        for file in "$(dirname "$file")"/*.args; do
            [ -f "$file" ] && basename "$file" .args
        done
        return 0
    fi
    for file in "$persist_dir"/*.args; do
        [ -f "$file" ] && basename "$file" .args
    done
    for file in $(namespace_persist_files); do
        name=$(basename "$(dirname "$file")")
        echo "$(basename "$file" .args)@$(basename "$(dirname "$(dirname "$file")")"):$name"
    done
}

# Function to handle --apply-persisted, called by the systemd unit
apply_persisted_rules() {
    local interface="$1"
    local file="$persist_dir/$interface.args"
    local args=() i

    [ -f "$file" ] || die "No persisted rules for $interface."

    # The device may appear before its address is configured; wait up to 30 seconds for IPv4
    for i in $(seq 1 60); do
        $ip_path -o -4 address show dev "$interface" 2>/dev/null | grep -q inet && break
        sleep 0.5
    done

    mapfile -t args < "$file"
    validate_saved_args "${args[@]}" || die "Invalid persisted arguments in $file."
    exec bash "$script_path" "${args[@]}" --allow-ssh
}

# Function to handle --watch-namespaces, run by the watcher service
watch_namespaces() {
    local interval="${LATENCYNINJA_WATCH_INTERVAL:-5}"
    declare -A applied_to=()
    echo "Watching persisted rules for containers and network namespaces (every ${interval}s)."
    while true; do
        reconcile_namespaces
        sleep "$interval"
    done
}

# Function to re-apply persisted rules in containers and namespaces that are new since last checked.
# Uses the applied_to array of watch_namespaces: persisted file -> "<namespace inode>:<interface index>".
reconcile_namespaces() {
    local file type name interface ref ns_file identity ifindex args=()
    for file in $(namespace_persist_files); do
        interface=$(basename "$file" .args)
        name=$(basename "$(dirname "$file")")
        type=$(basename "$(dirname "$(dirname "$file")")")
        ref="$type:$name"

        ns_file=$(ref_to_nsfile "$ref")
        [ -n "$ns_file" ] || continue  # container stopped or namespace missing
        ifindex=$(nsenter --net="$ns_file" $ip_path -o link show dev "$interface" 2>/dev/null | cut -d: -f1)
        [ -n "$ifindex" ] || continue  # interface not there (yet)
        identity="$(stat -L -c %i "$ns_file"):$ifindex"
        [ "${applied_to[$file]}" = "$identity" ] && continue

        # Rules already there (e.g. applied with --persist, or after a watcher restart): just remember them
        if nsenter --net="$ns_file" $ip_path link show "$(ifb_name_for "lni-" "$interface")" &>/dev/null || \
           nsenter --net="$ns_file" $ip_path link show "$(ifb_name_for "lne-" "$interface")" &>/dev/null; then
            applied_to[$file]="$identity"
            continue
        fi

        mapfile -t args < "$file"
        if ! validate_saved_args "${args[@]}"; then
            echo "Invalid persisted arguments in $file, skipping."
            applied_to[$file]="$identity"
            continue
        fi
        echo "Re-applying persisted rules for $interface in $(ref_description "$ref")."
        # The address may not be configured yet right after a restart; failures are retried next time
        if bash "$script_path" "--$type" "$name" "${args[@]}" --allow-ssh </dev/null >/dev/null 2>&1; then
            applied_to[$file]="$identity"
        else
            echo "  Failed, will retry."
        fi
    done
}
