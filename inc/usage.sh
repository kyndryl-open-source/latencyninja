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

# Function to display about information
about() {
    echo 
    echo "Latency Ninja $current_version"
    echo
    echo "Latency Ninja is a user-friendly wrapper for tc/netem. It is designed to emulate network perturbations for interfaces and networks. It is tailored for simulating network perturbations during chaos engineering exercises, and multi-region, distributed and hybrid cloud deployment simulations. This program is distributed under the GNU General Public License (GPL), it is distributed in the hope that it will be useful but provided without any warranty, implied or explicit."
    echo 
    echo "Usage:"
    echo
    echo "  $0 --interface <interface>"
    echo "          --dst_ip <destination_ip/destination_network:port>"
    echo "          [--src_ip <source_ip/destination_network>]"
    echo "          [--latency <latency>] [--jitter <jitter>] [--packet_loss <packet_loss>] [--duplicate <duplicate>] [--corrupt <corrupt>] [--reorder <reorder>]"
    echo
    echo "  Options:"
    echo
    echo "  -h, --help                                      Display help message."
    echo "  -a, --about                                     Display this about message."
    echo "  -v, --version                                   Display current version."
    echo    
    echo "  -q, --query                                     Display current tc rules."
    echo "  -r, --rollback                                  Rollback any networking conditions changes and redirections. Requires --interface."
    echo
    echo "  -i, --interface <interface>                     Desired network interface (e.g., eth0)."
    echo "  -s, --src_ip <ip,ip2,...>                       Desired source IP/Network. (default: IP of selected interface)."
    echo "  -d, --dst_ip <ip1:[prt1~],ip2:[prt1~prt2]...>   Desired destination IP(s)/Networks with optional ports. IPs can have multiple ports seperated by a ~."
    echo                                                         
    echo "                                                  Examples:"
    echo "                                                  - Single IP without port: 192.168.1.1"
    echo "                                                  - Single IP with one port: 192.168.1.1:80"
    echo "                                                  - Single IP with multiple ports: 192.168.1.1:80~443"
    echo "                                                  - Multiple IPs with and without ports: 192.168.1.1,192.168.1.2:80,192.168.1.4:80~443~8080"
    echo "                                                  - Multiple IPs and Subnets with and without ports: 192.168.1.1,192.168.2./24:80~443,192.168.3.0/24"    
    echo
    echo "  -w, --direction <ingress/egress/both>           Desired direction of the networking conditions (ingress, egress, or both). (default: both)."
    echo  
    echo "  -l, --latency <latency>                         Desired latency in milliseconds (e.g., 30 for 30ms)."
    echo "  -j, --jitter <jitter>                           Desired jitter in milliseconds (e.g., 3 for 3ms). Requires --latency."
    echo "  -x, --packet_loss <packet_loss>                 Desired packet loss in percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    echo "  -y, --duplicate <duplicate>                     Desired duplicate packet in percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    echo "  -z, --corrupt <corrupt>                         Desired corrupted packet in percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    echo "  -k, --reorder <reorder>                         Desired packet reordering in percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    echo
    echo "  --json <path/file.json>                         Path to JSON file."
    echo "  --update                                        Checks and updates to the latest version from Github."
    echo

    exit 0
}

# Function to display usage information
usage() {
    echo
    echo "Latency Ninja $current_version"
    echo "Simulate network perturbations for testing and optimization."
    echo "Usage: $0 --interface <interface> --dst_ip <destination> [options]"
    echo
    echo "Options:"
    echo "  -h, --help        Display help message."
    echo "  -a, --about       Display about message."
    echo "  -v, --version     Display current version."
    echo    
    echo "  -q, --query       Display current tc rules."
    echo "  -r, --rollback    Rollback networking changes. (Requires -i)"
    echo
    echo "  -i, --interface   Network interface (e.g., eth0)."
    echo "  -s, --src_ip      Source IP/Network (default: Interface IP)."
    echo "  -d, --dst_ip      Destination IPs/Networks with optional ports."
    echo
    echo "  -w, --direction   Direction of conditions (ingress, egress, or both)."
    echo
    echo "  -l, --latency     Latency in ms (e.g., 30)."
    echo "  -j, --jitter      Jitter in ms (Requires -l, e.g., 3)."
    echo "  -x, --packet_loss Packet loss percentage (e.g., 2 or 0.9%)."
    echo "  -y, --duplicate   Duplicate packet percentage (e.g., 2 or 0.9%)."
    echo "  -z, --corrupt     Corrupt packet percentage (e.g., 2 or 0.9%)."
    echo "  -k, --reorder     Packet reordering percentage (e.g., 2 or 0.9%)."
    echo
    echo "  --json            Path to JSON file."
    echo "  --update          Updates to the latest version."
    echo
    exit 0
}

# Function to display current version
version() {
    echo
    echo "Latency Ninja $current_version"
    echo
    exit 0
}