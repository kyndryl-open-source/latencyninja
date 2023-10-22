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

die() {
    local exit_code=${1:-$?}
    local script_name=${BASH_SOURCE[1]}
    local line_number=${BASH_LINENO[0]}
    local function_name=${FUNCNAME[1]}
    shift
    local message="${@:-"Unknown error occurred."}"

    if $debug; then
        # Detailed error information for debugging
        echo
        printf "[%s v%s] Debug Error:\nFunction %s at line %s of %s with message:\n%s\n" "$app_name" "$current_version" "$function_name" "$line_number" "$script_name" "$message"
    else
        # Basic error information
        printf "Error in %s: Function %s at line %s with message: %s\n" "$script_name" "$function_name" "$line_number" "$message"
    fi

    if [[ "$rollback_required" == 1 ]]; then
        if type rollback_everything &>/dev/null; then
            rollback_everything
        fi
        echo "Try again."
    fi

    exit $exit_code
}

debug_command() {
    local command="$*"
    echo "Running: $command"
    eval "$command"
    
    echo "Command exited with: $?"

    if [ $? -ne 0 ]; then
        echo "Error: Failed to execute $command"
        exit 1  # or any action you'd like to perform on failure
    fi
}

# Function to check full paths of commands
find_command_paths() {
    tc_path=$(command -v tc 2>/dev/null)
    ping_path=$(command -v ping 2>/dev/null)
    ip_path=$(command -v ip 2>/dev/null)
    modprobe_path=$(command -v modprobe 2>/dev/null)

    # Handle missing commands
    if [[ -z $tc_path ]]; then
        die "The 'tc' command is required but it's not installed. Please install it and retry."
    elif [[ -z $ping_path ]]; then
        die "The 'ping' command is required but it's not installed. Please install it and retry."
    elif [[ -z $ip_path ]]; then
        die "The 'ip' command is required but it's not installed. Please install it and retry."
    elif [[ -z $modprobe_path ]]; then
        die "The 'modprobe' command is required but it's not installed. Please install it and retry."
    fi
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
            local packages=("curl" "kmod" "iproute2" "inetutils-ping" "bc")
            ;;
        centos|fedora|rhel)
            local packages=("curl" "kmod" "iproute" "kernel-modules-extra" "iproute-tc" "iputils")
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
