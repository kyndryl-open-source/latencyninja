# Latency Ninja

Latency Ninja is a wrapper tool built around `tc/netem`, designed to empower you with the ability to simulate network perturbations on a specified network interface and destination IP address. It allows you to introduce latency, jitter, corruption, duplication, reordering, and packet loss to both ingress and egress traffic simultaneously, circumventing the limitations of `tc/netem` that typically would apply rules on egress only.

The initial releases are attempting to emulate the impact of a WAN (Wide Area Network) between compute nodes so application modelling on can be performed and validated where network latency is a significant component of the transaction turn around.  We focus on the term Round Trip Time (RTT) which is what you measure when you "ping" another machine on a network. RTT is the soum of the forward and reverse latency and is usually measured in milliseconds (ms) and at the scale of Wide Area network is dominated by the speed of light through Silica fibre. Light moves at approximately 200,000km/s through such fibre so for a 1000km run the forward latency is around 5ms and the RTT will be around 10ms. 

To keep it simple we will assume that forward and reverse latency is the same most users will want to run with this assumption. 

## Key Features

- 🕒 Latency: Control network delay, enabling you to mimic real-world scenarios with adjustable latency settings.
- 🔄 Jitter: Introduce variability to latency, replicating the unpredictable nature of network traffic.
- 💥 Corruption: Corrupt a defined percentage of packets to assess network and application resilience.
- ✨ Duplication: Duplicate packets to evaluate network performance under data replication scenarios.
- 🔀 Reordering: Test how your applications handle out-of-sequence packets with customizable reordering.
- 📦 Packet Loss: Simulate packet loss, a crucial factor in assessing application robustness.
- 📥 Ingress Traffic: Apply conditions to incoming traffic.
- 📤 Egress Traffic: Apply conditions to outgoing traffic.
- 📥 📤 Both Ingress and Egress Traffic: Apply conditions to both incoming and outgoing traffic for comprehensive (real life) testing.
- 🎯 Target Destination IP/Network: Specify the destination IP address or network to apply traffic conditions.
- 🎯 Target Source IP/Network: Specify the source IP address or network to apply traffic conditions.

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
    ./latencyninja.sh -h

 ## Usage
        
    Usage: ./latencyninja.sh -h -r -i <interface> -s <source_ip/network> -d <destination_ip/network> 
                [-l <latency>] [-j <jitter>] [-x <packet_loss>] [-y <duplicate>] 
                [-z <corrupt>] [-k <reorder>] [-p <num_pings>]

    Options:
    -h, --help                      Display this help message.
    -r, --rollback                  Rollback any networking conditions changes and redirections.

    -i, --interface <interface>     Network interface (e.g., eth0).
    -s, --src_ip <source_ip>        Source IP/Network. (default: IP of selected interface)
    -d, --dst_ip <destination_ip>   Destination IP/Network.
    -w, --direction <direction>     Desired direction of the networking conditions (ingress, egress, or both) (default: egress)

    -l, --latency <latency>         Desired latency in milliseconds (e.g., 30 for 3ms).
    -j, --jitter <jitter>           Desired jitter in milliseconds (e.g., 3 for 3ms). Use with -l|--latency only.
    -x, --packet-loss <packet_loss> Desired packet loss percentage (e.g., 1.5 for 1.5%).
    -y, --duplicate <duplicate>     Desired duplicate packet percentage (e.g., 1 for 1%).
    -z, --corrupt <corrupt>         Desired corrupted packet percentage (e.g., 5 for 5%).
    -k, --reorder <reorder>         Desired packet reordering percentage (e.g., 0.9 for 0.9%).
    -p, --pings <num_pings>         Desired number of pings to test (default: 5).

## Example
To simulate 100ms latency, 10ms jitter, and 5% packet loss on the eth0 interface for traffic going to 192.168.1.10, run:

    ./latency_ninja.sh -i eth0 -d 192.168.1.10 -l 100 -j 10 -x 5

To roll back previously applied network perturbations, run:

    ./latency_ninja.sh -i eth0 -r

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
- Schedule rollback.
- Auto download dependencies.
- Add traffic shaping capabilities.

## Contributing
We welcome contributions! If you'd like to contribute, please create a pull request with your changes.

## License
This project is licensed under the GNU General Public License v2.0. Please refer to the LICENSE file for more details.


