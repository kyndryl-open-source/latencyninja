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
    echo "  sudo $0 --interface <interface>"
    echo "          --dst_ip <destination_ip/destination_network:port>"
    echo "          [--src_ip <source_ip/destination_network>]"
    echo "          [--latency <latency>] [--jitter <jitter>] [--packet_loss <packet_loss>] [--duplicate <duplicate>] [--corrupt <corrupt>] [--reorder <reorder>] [--rate <rate>] [--protocol <tcp|udp|icmp>] [--mtu <bytes>]"
    echo "          [--profile <name>] [--duration <time> | --confirm-within <time>] [--probe <target>] [--run-in <background|screen|tmux>]"
    echo
    echo "  Options:"
    echo
    echo "  -h, --help                                      Display help message."
    echo "  -a, --about                                     Display this about message."
    echo "  -v, --version                                   Display current version."
    echo    
    echo "  -q, --query                                     Display current tc rules."
    echo "  --show-interfaces                               List network interfaces with their type, IPv4 address and Latency Ninja status."
    echo "  --stats                                         Show the traffic counters (packets, bytes, drops) of the rules applied (all interfaces, or only --interface)."
    echo "  --format <text|json>                            Output format of --query, --show-interfaces, --stats and --status. (default: text)."
    echo "  -r, --rollback                                  Rollback any networking conditions changes and redirections. Requires --interface."
    echo "  --check                                         Check for leftovers (orphaned ifb devices, stale state, broken persisted rules, old backups) and invalid profiles. Exits 1 if any are found."
    echo "  --clean                                         Check, then remove the leftovers after confirmation (--yes skips the confirmation). Active rules are never touched."
    echo
    echo "  --netns <name>                                  Apply/query/roll back inside a named network namespace (see 'ip netns list')."
    echo "  --pid <pid>                                     Apply/query/roll back inside the network namespace of a process."
    echo "  --container <name|id>                           Apply/query/roll back inside a running Docker or Podman container."
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
    echo "  -b, --rate <rate>                               Desired bandwidth limit per direction (e.g., 512kbit, 2mbit, 1gbit)."
    echo "  --protocol <tcp|udp|icmp>                       Only affect this protocol (default: all). tcp and udp can be combined with ports."
    echo "  --mtu <bytes>                                   Drop packets larger than this many bytes (an IP packet, e.g., 1400) to reproduce a path with a smaller MTU. Applies to the matching traffic and the chosen direction."
    echo "  -p, --profile <name>                            Apply a network profile (e.g., 3g, 4g, satellite). Explicit options override its values."
    echo "  --profiles                                      List the available profiles."
    echo "  -t, --duration <time>                           Automatically roll back after a duration (e.g., 30s, 10m, 2h), restoring the previous rules."
    echo "  --confirm-within <time>                         Dead-man switch: roll back automatically (e.g., after 2m) unless the rules are confirmed with --confirm. Requires systemd."
    echo "  --confirm                                       Keep the rules applied with --confirm-within. Requires --interface."
    echo "  --dry-run                                       Show what would be applied (the tc/ip commands) without changing anything."
    echo "  --allow-ssh                                     Apply rules even if they affect your SSH session (refused by default unless --duration is used)."
    echo
    echo "  --probe <target>                                Measure the effect of the rules with curl, before and after applying them. Target: http://host[:port][/path], https://... or tcp://host:port."
    echo "  --probe-count <n>                               Number of requests per measurement (default: 5)."
    echo
    echo "  --run-in <background|screen|tmux>               Run detached, so a dropped terminal or SSH session doesn't end the run. screen and tmux must be installed."
    echo "  --background                                    Same as --run-in background."
    echo "  --status [id]                                   List the detached runs, or show one with the end of its output."
    echo "  --wait <id>                                     Wait for a detached run to end, show its output and exit with its exit code."
    echo
    echo "  --json <path/file.json>                         Path to JSON file."
    echo "  --backup <path>                                 Directory for tc rules backup files (default: /tmp/)."
    echo "  --logging <path>                                Path for execution log file (default: /var/log/latencyninja/latencyninja.log)."
    echo "  --audit-log <path>                              Path for the audit log, one JSON line per change with who made it (default: /var/log/latencyninja/audit.log)."
    echo "  --persist                                       Re-apply the rules at boot and whenever the interface is re-created (requires systemd)."
    echo "                                                  Persisted rules are removed with --rollback."
    echo "  --save <file>                                   Save a restorable snapshot of the current rules (all interfaces, or only --interface)."
    echo "  --restore <file>                                Restore the rules from a snapshot or backup file (all interfaces in it, or only --interface)."
    echo "  --update                                        Checks and updates to the latest version from Github."
    echo

    exit 0
}

# Function to display usage information
usage() {
    echo
    echo "Latency Ninja $current_version"
    echo "Simulate network perturbations for testing and optimization."
    echo "Usage: sudo $0 --interface <interface> --dst_ip <destination> [options]"
    echo
    echo "Options:"
    echo "  -h, --help        Display help message."
    echo "  -a, --about       Display about message."
    echo "  -v, --version     Display current version."
    echo    
    echo "  -q, --query       Display current tc rules."
    echo "  --show-interfaces List interfaces, their type, IPv4 and Latency Ninja status."
    echo "  --stats           Show the traffic counters of the rules applied."
    echo "  --format          Output format of --query, --show-interfaces, --stats, --status (text or json)."
    echo "  -r, --rollback    Rollback networking changes. (Requires -i)"
    echo "  --check           Check for leftovers and invalid profiles."
    echo "  --clean           Check, then remove the leftovers (--yes: no confirmation)."
    echo
    echo "  --netns           Run inside a named network namespace."
    echo "  --pid             Run inside the network namespace of a process."
    echo "  --container       Run inside a Docker or Podman container."
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
    echo "  -b, --rate        Bandwidth limit per direction (e.g., 2mbit)."
    echo "  --protocol        Only affect tcp, udp or icmp traffic."
    echo "  --mtu             Drop packets larger than this many bytes (e.g., 1400)."
    echo "  -p, --profile     Network profile (e.g., 3g, 4g, satellite). --profiles lists them."
    echo "  -t, --duration    Automatic rollback after a duration (e.g., 10m)."
    echo "  --confirm-within  Roll back automatically unless confirmed with --confirm (e.g., 2m)."
    echo "  --confirm         Keep the rules applied with --confirm-within. (Requires -i)"
    echo "  --dry-run         Show what would be applied, change nothing."
    echo "  --allow-ssh       Apply rules even if they affect your SSH session."
    echo
    echo "  --probe           Measure the effect with curl before and after (http://, https:// or tcp://host:port)."
    echo "  --probe-count     Requests per measurement (default: 5)."
    echo "  --run-in          Run detached: background, screen or tmux. --background is --run-in background."
    echo "  --status          List the detached runs, or show one (--status <id>)."
    echo "  --wait            Wait for a detached run (--wait <id>)."
    echo
    echo "  --json            Path to JSON file."
    echo "  --backup          Directory for tc rules backup (default: /tmp/)."
    echo "  --logging         Path for execution log (default: /var/log/latencyninja/latencyninja.log)."
    echo "  --audit-log       Path for the audit log (default: /var/log/latencyninja/audit.log)."
    echo "  --persist         Re-apply rules at boot and when the interface is re-created."
    echo "  --save            Save a restorable snapshot of current rules to a file."
    echo "  --restore         Restore rules from a snapshot or backup file."
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