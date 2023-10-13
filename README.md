# Latency Ninja

Latency Ninja is a wrapper tool built around `tc/netem`, designed to empower you with the ability to simulate network perturbations on a specified network interface and destination IP address. It allows you to introduce latency, jitter, corruption, duplication, reordering, and packet loss to both ingress and egress traffic simultaneously, circumventing the limitations of `tc/netem` that typically would apply rules on egress only.

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

## Compatibility

Latency Ninja is compatible with Red Hat/CentOS/Fedora/Debian/Ubuntu Linux-based systems and requires superuser privileges to run.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Example](#Example)
- [Screenshot](#Screenshot)
- [Warning](#warning)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#Roadmap)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites

1. Make sure you have `tc` and `netem` installed on your system.
2. Root or superuser privileges are required to run the script.

## Installation

    git clone https://github.com/haythamelkhoja/latencyninja
    cd latencyninja
    chmod +x ./latencyninja.sh    
    ./latencyninja.sh --help

 ## Usage
        
    Usage: -i <interface> -d <destination> [OPTIONS]
        
    Options:"
      -h, --help                                             Display this help message."
      -r, --rollback                                         Rollback any networking conditions changes and redirections. Requires -i"

      -i, --interface <interface>                            Desired network interface (e.g., eth0)."
      -s, --src_ip <ip,ip2,...>                              Desired source IP/Networks. (default: IP of selected interface)"    
      -d, --dst_ip <ip:[port1~]...,ip2:[port1~port2~.],...>  Desired destination IP(s)/Networks with optional ports. IPs can have multiple ports seperated by ~."
                                                             Examples:"
                                                             - Single IP without port: '192.168.1.1'"
                                                             - Single IP with one port: '192.168.1.1:80'"
                                                             - Single IP with multiple ports: '192.168.1.1:80~443'"
                                                             - Multiple IPs with and without ports: '192.168.1.1,192.168.1.2:80,192.168.1.4:80~443~8080'"
                                                             - Multiple IPs and Subnets with and without ports: '192.168.1.1,192.168.2./24:80~443,192.168.3.0/24'"    

      -w, --direction <ingress/egress/both>                   Desired direction of the networking conditions (ingress, egress, or both). (default: both)"

      -l, --latency <latency>                                 Desired latency in milliseconds (e.g., 30 for 30ms)."
      -j, --jitter <jitter>                                   Desired jitter in milliseconds (e.g., 3 for 3ms). Use with -l|--latency only."
      -x, --packet_loss <packet_loss>                         Desired packet loss percentage (e.g., 2 for 2% or 0.9 for 0.9%)."    
      -y, --duplicate <duplicate>                             Desired duplicate packet percentage (e.g., 2 for 2% or 0.9 for 0.9%).."
      -z, --corrupt <corrupt>                                 Desired corrupted packet percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
      -k, --reorder <reorder>                                 Desired packet reordering percentage (e.g., 2 for 2% or 0.9 for 0.9%)."
    
## Example
To simulate 100ms latency, 1.3ms jitter, and 5% packet loss on the eth0 interface for traffic going to 192.168.1.10, run:

    ./latencyninja.sh \
            --interface eth0 \
            --destination 192.168.1.10 \
            --latency 100 \
            --jitter 1.3 \
            --packet-loss 5   

To roll back previously applied network perturbations, run:

    ./latencyninja.sh -i eth0 -r

## Screenshot

<img width="1218" alt="Screenshot" src="https://github.com/haythamelkhoja/latencyninja/assets/450702/2da458ed-8ec6-400c-be85-bf448cfd783a">

## Warning
- Any changes made by Latency Ninja will not persist after a reboot or a network restart (yet)

## Troubleshooting
 - Permission Denied: Make sure you're running the script with superuser privileges.
 - Interface Error: Ensure that the provided network interface exists and is up.
 - Missing Parameters: Always ensure that mandatory parameters like -i and -d are provided, except for when rolling back (using -r), which requires -i only.

## Roadmap
- Persist network perturbations policies after network interface restart and reboots.
- Schedule rollbacks.
- Auto download dependencies.
- Add traffic shaping capabilities.

## Contributing
We welcome contributions! If you'd like to contribute, please create a pull request with your changes.

## License
This project is licensed under the GNU General Public License v2.0. Please refer to the LICENSE file for more details.