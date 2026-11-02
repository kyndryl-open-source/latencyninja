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

# Global die() function
die() {
    local exit_code
    if [[ $1 =~ ^[0-9]+$ ]]; then
        exit_code=$1
        shift
    else
        exit_code=1
    fi
    
    local message="${@:-"Unknown error occurred."}"

    if [ "$debug" = true ]; then
        local script_name="${BASH_SOURCE[1]:-unknown_script}"
        local line_number="${BASH_LINENO[0]:-unknown_line}"
        local function_name="${FUNCNAME[1]:-unknown_function}"
        local script_vars
        
        # Detailed error information for debugging
        printf "Debug Error:\nFunction %s at line %s of %s with message: %s\n" "$function_name" "$line_number" "$script_name" "$message"
        script_vars=$(declare -p | grep -v '^declare \-[^ ]* [A-Z_][A-Z0-9_]*=')
        printf "Script Variables:\n%s\n" "$script_vars"

    else
        # Basic error information
        printf "Error: %s\n" "$message"
    fi

    exit $exit_code
}

# Function to check for root/sudo privileges
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo
        echo -e "This script must be run as root. Please run it again with 'sudo'." 1>&2
        exit 1
    fi
}

# Function to check packages
check_system_requirements() {
    # Detect OS type
    if [ ! -f /etc/os-release ]; then
        echo "Cannot identify OS type."
        exit 1
    fi

    . /etc/os-release
    local os_type="$ID"
    local missing_packages=()

    case $os_type in
        debian|ubuntu)
            local packages=("kmod" "iproute2" "jq")
            # git is only required for --update, curl for --update and --probe, screen or tmux for --run-in
            [[ "$update_requested" -eq 1 ]] && packages+=("git")
            [[ "$update_requested" -eq 1 || "$probe_requested" -eq 1 ]] && packages+=("curl")
            [[ "$run_in_requested" == "screen" || "$run_in_requested" == "tmux" ]] && packages+=("$run_in_requested")
            ;;
        centos|fedora|rhel)
            local packages=("kmod" "iproute" "kernel-modules-extra" "iproute-tc" "jq")
            # git is only required for --update, curl for --update and --probe, screen or tmux for --run-in
            [[ "$update_requested" -eq 1 ]] && packages+=("git")
            [[ "$update_requested" -eq 1 || "$probe_requested" -eq 1 ]] && packages+=("curl")
            [[ "$run_in_requested" == "screen" || "$run_in_requested" == "tmux" ]] && packages+=("$run_in_requested")
            ;;
        *)
            echo "Unsupported OS: $os_type"
            exit 1
            ;;
    esac

    for package in "${packages[@]}"; do
        case $os_type in
            debian|ubuntu)
                if ! dpkg -l | grep -q "^ii\s\+$package\s"; then
                    missing_packages+=("$package")
                fi
                ;;
            centos|fedora|rhel)
                if ! rpm -q "$package" &>/dev/null; then
                    missing_packages+=("$package")
                fi
                ;;
        esac
    done

    if [ "${#missing_packages[@]}" -gt 0 ]; then
        echo "Missing packages: ${missing_packages[*]}"
        echo "Would you like to install them now? (yes/no)"
        read -r install_answer
        if [ "$install_answer" = "yes" ]; then
            case $os_type in
                debian|ubuntu)
                    sudo apt install "${missing_packages[@]}"
                    ;;
                centos|fedora|rhel)
                    sudo dnf install "${missing_packages[@]}"
                    ;;
            esac
        else
            echo "Please install the missing packages and run the script again."
            exit 1
        fi
    fi    
}

# Function to load the ifb module
load_ifb_module() {
    if ! lsmod | grep -q ifb; then
        $modprobe_path ifb || die "Failed to load the ifb module."
    fi
}

# Function to load the act_police module, which --mtu uses to drop packets that are too large. It is in the kernel
# modules package that also has ifb and netem (linux-modules-extra on Ubuntu, kernel-modules-extra on Fedora).
load_police_module() {
    [ -n "$mtu" ] || return 0
    if ! lsmod | grep -q '^act_police'; then
        $modprobe_path act_police || die "The --mtu option needs the act_police kernel module, which could not be loaded. Install the extra kernel modules (linux-modules-extra on Debian/Ubuntu, kernel-modules-extra on Fedora/Red Hat)."
    fi
}
