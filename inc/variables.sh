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
declare -g app_name="Latency Ninja" current_version="1.8"  # Name and version of the application.

# Network Interfaces
declare -g ifb0_interface="ifb0" ifb1_interface="ifb1" eth_interface=""  # Network interfaces for traffic shaping.

# IP Addresses
declare -g local_ip="" src_ip=() dst_ip=()  # Local IP address, source and destination IPs for traffic shaping.

# Traffic Shaping Parameters
declare -g latency="" jitter="" packet_loss="" duplicate="" corrupt="" reorder=""  # Parameters for simulating network conditions.

# Options and Flags
declare -g direction="both"  # Traffic direction for shaping (options: both, inbound, outbound).
declare -g interface_provided=0 jitter_provided=0 latency_provided=0  # Flags for user-provided options.
declare -g rollback_required=0 rollback_done=0 ips_swapped=0  # Flags for script behavior and state.

# Declare global variables for command paths
declare -g tc_path="" ping_path="" ip_path="" mod_probe=""

# Debugging
declare -g debug=false  # Flag for enabling/disabling debug mode.