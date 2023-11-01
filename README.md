# Latency Ninja

<img src="latencyninjalogosmall.png" alt="Latency Ninja" align="right" />  Latency Ninja is a user-friendly wrapper for `tc/netem`. It is designed to emulate network perturbations for interfaces and networks. It is tailored for simulating network perturbations during chaos engineering exercises, and multi-region, distributed and hybrid cloud deployment simulations. It allows you to introduce latency, jitter, corruption, duplication, reordering, and packet loss to both ingress and egress traffic simultaneously, circumventing the limitations of `tc/netem` that typically would apply rules on egress only. 

This program is distributed under the GNU General Public License (GPL), it is distributed in the hope that it will be useful but provided without any warranty, implied or explicit.

## Key Features

* 🕒 Latency: Control network delay, enabling you to mimic real-world scenarios with adjustable latency settings.
* 🔄 Jitter: Introduce variability to latency, replicating the unpredictable nature of network traffic.
* 💥 Corruption: Corrupt a defined percentage of packets to assess network and application resilience.
* ✨ Duplication: Duplicate packets to evaluate network performance under data replication scenarios.
* 🔀 Reordering: Test how your applications handle out-of-sequence packets with customizable reordering.
* 👻 Packet Loss: Simulate packet loss, a crucial factor in assessing application robustness.
* 🧭 Direction: Apply conditions to both incoming and outgoing traffic for comprehensive real-world testing. 
  * 📥 Ingress and 📤 Egress: Apply conditions to both incoming and outgoing traffic simultenaously. 
  * 📥 Ingress Traffic Only: Apply conditions to incoming traffic.
  * 📤 Egress Traffic Only: Apply conditions to outgoing traffic.
* 🎯 Target Multiple Destination IP/Networks: Specify the destination IP addresses or networks.
* 🌍 Filter by Source IP/Network: Specify the source IP address or network.
* <span style="color:red;font-weight:bold;">{ }</span> JSON Support: Allows performing network conditions programmatically.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Compatibility](#compatibility)
- [Installation](#installation)
- [Usage](#usage)
- [Examples](#Examples)
- [Updating](#Updating)
- [Warning](#warning)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#Roadmap)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites

1. Latency Ninja requires the following packages installed on the system, however it will also attempt to dnf install/apt install missing packages:
      - kmod, iproute, kernel-modules-extra, iproute-tc, iputils, curl, git, jq.
2. `root` or `sudo` privileges are required.

## Compatibility

Latency Ninja is compatible with Red Hat/CentOS/Fedora/Debian/Ubuntu Linux-based systems and requires superuser privileges to run.

## Installation

Clone this repository:

      git clone https://github.com/haythamelkhoja/latencyninja

Browse to directory:

      cd latencyninja

Add executible permissions:

      chmod +x ./latencyninja
  
 ## Usage
          
      ./latencyninja --interface <interface> 
                     --dst_ip <destination IP/Network:port~port~port> 
                     [--src_ip <source IP/network>] 
                     [--direction <direction>]
                     [--latency <latency>] [--jitter <jitter>] [--packet_loss <packet_loss>] [--duplicate <duplicate>] [--corrupt <corrupt>] [--reorder <reorder>]

      Options:

      -h, --help                                      Display thelp message.
      -a, --about                                     Display about message.
      -v, --version                                   Display current version.

      -q, --query                                     Display current tc rules applied.
      -r, --rollback                                  Rollback any networking conditions changes and redirections. Requires --interface.

      -i, --interface <interface>                     Desired network interface (e.g., eth0).
      -s, --src_ip <ip,ip2,...>                       Desired source IP/Network. (default: IP of selected interface).
      -d, --dst_ip <ip:[prt1~],ip2:[prt1~prt2~]..>    Desired destination IP(s)/Networks with optional ports. IPs can have multiple ports seperated by a ~.

                                                      Examples:
                                                      - Single IP without port: 192.168.1.1
                                                      - Single IP with one port: 192.168.1.1:80
                                                      - Single IP with multiple ports: 192.168.1.1:80~443
                                                      - Multiple IPs with and without ports: 192.168.1.1,192.168.1.2:80,192.168.1.4:80~443~8080
                                                      - Multiple IPs and Subnets with and without ports: 192.168.1.1,192.168.2.0/24:80~443,192.168.3.0/24

      -w, --direction <ingress/egress/both>           Desired direction of the networking conditions (ingress, egress, or both). (default: both).

      -l, --latency <latency>                         Desired latency in milliseconds (e.g., 30 for 30ms).
      -j, --jitter <jitter>                           Desired jitter in milliseconds (e.g., 3 for 3ms). Requires --latency.
      -x, --packet_loss <packet_loss>                 Desired packet loss in percentage (e.g., 2 for 2% or 0.9 for 0.9%).
      -y, --duplicate <duplicate>                     Desired duplicate packet in percentage (e.g., 2 for 2% or 0.9 for 0.9%).
      -z, --corrupt <corrupt>                         Desired corrupted packet in percentage (e.g., 2 for 2% or 0.9 for 0.9%).
      -k, --reorder <reorder>                         Desired packet reordering in percentage (e.g., 2 for 2% or 0.9 for 0.9%).

      --json <path/file.json>                         Path to JSON file.
      --update                                        Checks and updates to the latest version from Github.

## Examples

      ./latencyninja \ 
                  --interface eth0 \
                  --dst_ip 192.168.100.123 \
                  --latency 5 

      ./latencyninja \ 
                  --interface eth0 \
                  --dst_ip 192.168.100.123:80~443 \
                  --latency 5 --jitter 0.1 \
                  --direction ingress

      ./latencyninja \ 
                  --interface eth0 \
                  --dst_ip 192.168.100.0/24:80~443,192.168.120.2:8080~9090 \
                  --latency 5 --jitter 0.1 --packet-loss 0.5 --duplicate 0.1

      ./latencyninja \
                  --interface eth0 \
                  --src_ip 192.168.100.123 \
                  --dst_ip 192.168.100.121 \
                  --latency 5 --jitter 0.2 
                  --direction egress

To use a JSON file using the --json option, run:

      ./latencyninja \
                  --json file.json


Make sure the JSON file is formated using the following template:

      {
            "interface": "ens192",
            "src_ip": "192.168.100.121",
            "dst_ip": "192.168.100.123:80~443,192.168.100.0/24",
            "direction": "egress",
            "latency": "30",
            "jitter": "5",
            "packet_loss": "0.5",
            "duplicate": "1",
            "corrupt": "0.1",
            "reorder": "2"
      }

To display current network perturbations rules, run:

      ./latencyninja --query

To roll back previously applied network perturbations, run:

      ./latencyninja \
                  --interface eth0 \
                  --rollback

## Updating

To update Latency Ninja to the lastest version, run:

    ./latencyninja --update

## Warning
- Any changes made by Latency Ninja will not persist after a reboot or a network restart (yet)

## Troubleshooting
 - Permission Denied: Make sure you're running the script with superuser privileges.
 - Interface Error: Ensure that the provided network interface exists and is up.
 - Missing Parameters: Always ensure that mandatory parameters like -i and -d are provided, except for when rolling back (using -r), which requires -i only.

## Roadmap
- Persist network perturbations policies after network interface restart and reboots.
- Schedule rollbacks.

## Contributing
We welcome contributions! If you'd like to contribute, please create a pull request with your changes.

## License
This project is licensed under the GNU General Public License v2.0. Please refer to the LICENSE file for more details.