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

# Application Information
declare -g app_name="Latency Ninja" current_version="1.19"

# Updater Information
declare -g repo_url="https://github.com/haythamelkhoja/latencyninja.git" version_url="https://raw.githubusercontent.com/haythamelkhoja/latencyninja/main/version.txt" version_file="version.txt" 

# Network Interfaces
declare -g ifb0_interface="ifb0" ifb1_interface="ifb1" eth_interface=""

# Local IP address, source and destination IPs.
declare -g local_ip="" src_ip=() dst_ip=()  

# JSON File
declare -g json_file="" json_interface="" json_src_ip="" json_dst_ip="" json_latency="" json_jitter="" json_packet_loss="" json_duplicate="" json_corrupt="" json_reorder=""

# Network perturbation earameters
declare -g latency="" jitter="" packet_loss="" duplicate="" corrupt="" reorder="" 

# Options and Flags
declare -g direction="both"  # Traffic direction for shaping (options: both, inbound, outbound).
declare -g interface_provided=0 jitter_provided=0 latency_provided=0  # Flags for user-provided options.
declare -g rollback_required=0 rollback_done=0 ips_swapped=0  # Flags for script behavior and state.

# Function to check full paths of commands
find_command_paths() {
    local required_commands=("tc" "ping" "ip" "modprobe" "git" "curl" "jq")
    local cmd
    local cmd_path
    local var_name

    for cmd in "${required_commands[@]}"; do
        cmd_path=$(command -v "$cmd" 2>/dev/null)
        if [[ -z $cmd_path ]]; then
            die "The '$cmd' command is required but it's not installed. Please install it and retry."
        else
            var_name="${cmd}_path"
            declare -g "$var_name=$cmd_path"
        fi
    done
}

# Debugging
declare -g debug=false