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
* 🔗 Multiple interfaces: Shape several interfaces at once, including bonded (`bond0`) and WireGuard (`wg0`) interfaces.
* 💾 Snapshots: Save the current rules to a file and restore them later. Every change also writes a restorable backup.
* 📌 Persistence: Optionally re-apply rules at boot and whenever the interface is re-created (systemd).
* 📶 Bandwidth: Limit throughput per direction to emulate slow links.
* 🗂️ Profiles: Ready-made network profiles (3G, 4G, 5G, satellite, cross-region links, lossy Wi-Fi) and your own.
* ⏲️ Timed rollback: Automatically restore the previous rules after a duration.

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
      -b, --rate <rate>                               Desired bandwidth limit per direction (e.g., 512kbit, 2mbit, 1gbit).
      -p, --profile <name>                            Apply a network profile (e.g., 3g, 4g, satellite). Explicit options override its values.
      --profiles                                      List the available profiles.
      -t, --duration <time>                           Automatically roll back after a duration (e.g., 30s, 10m, 2h), restoring the previous rules.

      --json <path/file.json>                         Path to JSON file.
      --backup <path>                                 Directory for tc rules backup files (default: /tmp/).
      --logging <path>                                Path for execution log file (default: /tmp/latencyninja.log).
      --persist                                       Re-apply the rules at boot and whenever the interface is re-created (requires systemd).
                                                      Persisted rules are removed with --rollback.
      --save <file>                                   Save a restorable snapshot of the current rules (all interfaces, or only --interface).
      --restore <file>                                Restore the rules from a snapshot or backup file (all interfaces in it, or only --interface).
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
            "reorder": "2",
            "rate": "10mbit",
            "profile": "4g",
            "duration": "15m"
      }

To display current network perturbations rules, run:

      ./latencyninja --query

To roll back previously applied network perturbations, run:

      ./latencyninja \
                  --interface eth0 \
                  --rollback

Optional JSON keys: `rate`, `profile` (explicit values in the file take precedence over the profile) and `duration`.

## Bandwidth Limits

Limit the bandwidth of the targeted traffic with `--rate`. Units are `bit`, `kbit`, `mbit`, `gbit` (bits per second) or `bps`, `kbps`, `mbps`, `gbps` (bytes per second). Unlike latency, which is split between ingress and egress when using `--direction both`, the rate applies to each direction:

      ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --rate 2mbit

## Profiles

Profiles apply a realistic combination of conditions in one option. List them with `--profiles`:

| Profile | Latency (RTT) | Jitter | Loss | Rate |
|---|---|---|---|---|
| `3g` | 200ms | 40ms | 1% | 1500kbit |
| `4g` | 60ms | 15ms | 0.2% | 20mbit |
| `5g` | 20ms | 5ms | | 100mbit |
| `satellite` | 600ms | 20ms | 0.5% | 10mbit |
| `leo-satellite` | 40ms | 10ms | 0.5% | 100mbit |
| `transatlantic` | 80ms | 5ms | | |
| `transpacific` | 150ms | 10ms | | |
| `lossy-wifi` | 15ms | 10ms | 3% (+0.5% duplicates) | 20mbit |

Options given explicitly take precedence over the profile's values:

      ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --profile 4g
      ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --profile 4g --latency 150

Add your own profiles as JSON files in `/etc/latencyninja/profiles/<name>.json`, using the same keys as `--json` plus a `description`. A custom profile with the same name as a built-in one replaces it. Snapshots and persisted rules store the resolved values, so editing a profile later doesn't change them.

## Timed Rollback

Use `--duration` to apply rules for a limited time, for example during a chaos experiment or to stay safe on a remote machine:

      ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --latency 200 --duration 15m

When the time is up, the interface is restored from the backup taken just before the rules were applied: if it had no rules it is rolled back, and if it had earlier rules those are re-applied. `--query` shows pending rollbacks; `--rollback` ends the rules earlier, and applying new rules to the interface cancels its pending rollback. Durations accept `s`, `m`, `h` and `d` (default seconds). Timed rollback uses a systemd timer, so it requires systemd and can't be combined with `--persist`.

## Snapshots and Backups

Save the rules currently applied by Latency Ninja on all interfaces (or a single one with `--interface`):

      ./latencyninja --save /root/before-test.snap

Restore them later. Interfaces in scope that have rules but weren't in the snapshot are rolled back, so restoring a snapshot taken before any rules were applied returns the system to a clean state:

      ./latencyninja --restore /root/before-test.snap
      ./latencyninja --restore /root/before-test.snap --interface eth0   # only eth0

Every time rules are applied, a snapshot of the previous state is written to the backup directory (`--backup`, default `/tmp`). Restoring it undoes that change; the exact command is printed after each run.

Snapshots are plain text with one argument per line and are never executed by a shell.

## Persistence

By default rules are lost at reboot or when an interface is re-created. Add `--persist` to keep them:

      ./latencyninja --interface wg0 --dst_ip 10.30.0.2 --latency 50 --persist

The configuration is saved in `/etc/latencyninja/persist/` and a udev rule starts `latencyninja@<interface>.service` each time the interface appears: at boot, and whenever it is re-created (e.g. `wg-quick down/up`, NetworkManager re-creating a bond). Rules already survive a plain link down/up. The unit runs Latency Ninja from its current location, so re-run with `--persist` if you move it.

`--query` lists persisted interfaces, applying new rules with `--persist` replaces the persisted ones, and `--rollback --interface <interface>` removes them.

## Bonded and WireGuard Interfaces

Rules can be applied to bonded and WireGuard interfaces like any other interface. On a bond, rules keep working through slave failover. On a WireGuard interface, rules apply to the traffic inside the tunnel; to affect the encrypted traffic, apply rules to the underlying interface with the peer's endpoint as `--dst_ip`.

Each interface uses its own pair of `ifb` devices (`lni-<interface>` for ingress and `lne-<interface>` for egress), so several interfaces can be shaped at the same time.

## Updating

To update Latency Ninja to the lastest version, run:

    ./latencyninja --update

## Warning
- Changes made by Latency Ninja do not persist after a reboot or when an interface is re-created unless `--persist` is used.

## Troubleshooting
 - Permission Denied: Make sure you're running the script with superuser privileges.
 - Interface Error: Ensure that the provided network interface exists and is up.
 - Missing Parameters: Always ensure that mandatory parameters like -i and -d are provided, except for when rolling back (using -r), which requires -i only.

## Roadmap
- Target containers and network namespaces (Docker, Podman, `--netns`, `--pid`).
- IPv6 support.

## Contributing
We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, tests and release process.

## License
This project is licensed under the GNU General Public License v2.0. Please refer to the LICENSE file for more details.