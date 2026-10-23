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

# Function to get the systemd unit name for an interface
persist_unit_name() {
    echo "latencyninja@$(systemd-escape "$1").service"
}

# Function to check if an interface has persisted rules (persistence only applies to the host namespace)
is_persisted() {
    ! in_namespace && [ -f "$persist_dir/$1.args" ]
}

# Function to check that persistence can be used on this system
check_persist_supported() {
    if ! command -v systemctl &>/dev/null || [ ! -d /run/systemd/system ]; then
        die "The --persist option requires systemd."
    fi
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
    local unit
    unit=$(persist_unit_name "$interface")

    mkdir -p "$persist_dir" && chmod 700 "$persist_dir"
    build_canonical_args > "$persist_dir/$interface.args" || die "Failed to save persisted rules for $interface."
    install_persist_unit || die "Failed to install $unit_file."
    systemctl daemon-reload
    udevadm control --reload &>/dev/null
    echo "Persisted: rules for $interface will be re-applied at boot and when the interface is re-created ($unit)."
}

# Function to remove the persisted configuration of an interface
unpersist_rules() {
    local interface="$1"
    is_persisted "$interface" || return 0

    rm -f "$persist_dir/$interface.args"
    systemctl stop "$(persist_unit_name "$interface")" &>/dev/null
    echo "Removed persisted rules for $interface."
}

# Function to list interfaces with persisted rules
persisted_interfaces() {
    local file
    in_namespace && return 0
    for file in "$persist_dir"/*.args; do
        [ -f "$file" ] && basename "$file" .args
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
    exec bash "$script_path" "${args[@]}"
}
