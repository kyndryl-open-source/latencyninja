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
* 🛡️ SSH lockout guard: Refuses rules that would affect your own SSH session, unless they roll back automatically.
* 👀 Dry run: `--dry-run` shows the exact `tc`/`ip` commands that would be run, without changing anything.
* 🧹 Check and clean: `--check` finds leftovers and invalid settings, `--clean` removes them. Inputs are validated and normalized before anything is applied.
* 📦 Containers: Target a single Docker or Podman container, a network namespace or a process instead of the whole host.

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
      - CentOS/Fedora/Red Hat: kmod, iproute, kernel-modules-extra, iproute-tc, curl, jq
      - Debian/Ubuntu: kmod, iproute2, curl, jq
      - git is also required to use `--update`.
      - `--persist` and `--duration` require systemd.
2. `root` or `sudo` privileges are required.

## Compatibility

Latency Ninja is compatible with Red Hat/CentOS/Fedora/Debian/Ubuntu Linux-based systems and requires superuser privileges to run.

## Installation

Clone this repository:

      git clone https://github.com/kyndryl-open-source/latencyninja

Browse to directory:

      cd latencyninja

Add executible permissions:

      chmod +x ./latencyninja
  
## Usage

See **[USAGE.md](USAGE.md)** for detailed examples of every feature.

      sudo ./latencyninja [--container <name> | --netns <name> | --pid <pid>]
                          --interface <interface>
                          --dst_ip <destination IP/Network:port~port~port>
                          [--src_ip <source IP/network>]
                          [--direction <direction>]
                          [--latency <latency>] [--jitter <jitter>] [--packet_loss <packet_loss>] [--duplicate <duplicate>] [--corrupt <corrupt>] [--reorder <reorder>] [--rate <rate>]
                          [--profile <name>] [--duration <time>] [--persist]

      Options:

      -h, --help                                      Display the help message.
      -a, --about                                     Display about message.
      -v, --version                                   Display current version.

      -q, --query                                     Display current tc rules applied.
      --show-interfaces                               List network interfaces with their type, IPv4 address and Latency Ninja status.
      -r, --rollback                                  Rollback any networking conditions changes and redirections. Requires --interface.

      --container <name|id>                           Apply/query/roll back inside a running Docker or Podman container.
      --netns <name>                                  Apply/query/roll back inside a named network namespace (see 'ip netns list').
      --pid <pid>                                     Apply/query/roll back inside the network namespace of a process.

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
      --check                                         Check for leftovers (orphaned ifb devices, stale state, broken persisted rules, old backups) and invalid profiles. Exits 1 if any are found.
      --clean                                         Check, then remove the leftovers after confirmation (--yes skips the confirmation). Active rules are never touched.
      --allow-ssh                                     Apply rules even if they affect your SSH session (refused by default unless --duration is used).
      --update                                        Checks and updates to the latest version from Github.

## Examples

More examples, with explanations, are in [USAGE.md](USAGE.md).

Add 50 ms of latency to all traffic with one host:

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --latency 50

Latency with jitter on two ports of a host, incoming traffic only:

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123:80~443 \
                          --latency 100 --jitter 10 --direction ingress

Several destinations and subnets with loss and duplication:

      sudo ./latencyninja --interface eth0 \
                          --dst_ip 192.168.100.0/24:80~443,192.168.120.2:8080~9090 \
                          --latency 5 --jitter 0.1 --packet_loss 0.5 --duplicate 0.1

Only traffic from one local address, outgoing only:

      sudo ./latencyninja --interface eth0 --src_ip 192.168.100.123 --dst_ip 192.168.100.121 \
                          --latency 5 --jitter 0.2 --direction egress

Limit bandwidth to 2 Mbit/s:

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --rate 2mbit

Emulate a 4G connection, or 4G with more latency:

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --profile 4g
      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --profile 4g --latency 150

Make a dependency unreachable for 2 minutes, then restore automatically:

      sudo ./latencyninja --interface eth0 --dst_ip 10.0.5.20 --packet_loss 100 --duration 2m

Keep cross-region latency to a database network across reboots:

      sudo ./latencyninja --interface eth0 --dst_ip 10.50.0.0/16:5432 --profile transatlantic --persist

Slow down a single container for 15 minutes:

      sudo ./latencyninja --container checkout --interface eth0 --dst_ip 172.17.0.0/16 \
                          --latency 250 --jitter 50 --duration 15m

Save the current rules, experiment, and put everything back:

      sudo ./latencyninja --save /root/before.snap
      sudo ./latencyninja --interface bond0 --dst_ip 10.40.0.0/24 --profile satellite
      sudo ./latencyninja --restore /root/before.snap

List interfaces and check what is applied:

      sudo ./latencyninja --show-interfaces
      sudo ./latencyninja --query

To use a JSON file using the --json option, run:

      sudo ./latencyninja \
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

To list the interfaces you can apply rules to, with their type (ethernet, bond, WireGuard, ...), IPv4 address and whether Latency Ninja rules, persistence or a timed rollback are active, run:

      sudo ./latencyninja --show-interfaces

To display current network perturbations rules, run:

      sudo ./latencyninja --query

To roll back previously applied network perturbations, run:

      sudo ./latencyninja \
                  --interface eth0 \
                  --rollback

Every option that applies rules is supported, including `persist` (`true`/`false`), `backup`, `logging` and the target (`container`, `netns` or `pid`). `src_ip` and `dst_ip` can also be arrays, numbers can be written without quotes, and unknown keys are rejected. See [USAGE.md](USAGE.md#json-files) for the full list.

## Bandwidth Limits

Limit the bandwidth of the targeted traffic with `--rate`. Units are `bit`, `kbit`, `mbit`, `gbit` (bits per second) or `bps`, `kbps`, `mbps`, `gbps` (bytes per second). Unlike latency, which is split between ingress and egress when using `--direction both`, the rate applies to each direction:

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --rate 2mbit

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

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --profile 4g
      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --profile 4g --latency 150

Add your own profiles as JSON files in `/etc/latencyninja/profiles/<name>.json`, using the same keys as `--json` plus a `description`. A custom profile with the same name as a built-in one replaces it. Snapshots and persisted rules store the resolved values, so editing a profile later doesn't change them.

## Timed Rollback

Use `--duration` to apply rules for a limited time, for example during a chaos experiment or to stay safe on a remote machine:

      sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --latency 200 --duration 15m

When the time is up, the interface is restored from the backup taken just before the rules were applied: if it had no rules it is rolled back, and if it had earlier rules those are re-applied. `--query` shows pending rollbacks; `--rollback` ends the rules earlier, and applying new rules to the interface cancels its pending rollback. Durations accept `s`, `m`, `h` and `d` (default seconds). Timed rollback uses a systemd timer, so it requires systemd and can't be combined with `--persist`.

## SSH Lockout Guard

Rules that match the traffic of your own SSH session (packet loss, a low rate or a long delay towards your client) can make the session unusable, and with it the way to roll the rules back. Before applying rules, Latency Ninja looks for SSH sessions that reach the machine through the target interface and refuses rules that would affect them:

      Error: These rules would also affect your SSH session from 10.0.0.9 on eth0 and could lock you out. ...

Exclude your address from `--src_ip`/`--dst_ip`, add `--duration` so the rules roll back automatically (a warning is shown instead), or add `--allow-ssh` (`"allow_ssh": true` in JSON files) to apply them anyway. The check is conservative: a rule counts as matching when it covers the client address with port 0 (any), the client's port or the SSH server port. Restoring snapshots and persisted rules is not blocked.

## Check and Clean

Latency Ninja leaves some state behind that can get out of step with the system: ifb devices, saved rules, timers, persisted rules, backups. `--check` looks for it without changing anything, and `--clean` removes what it can after you confirm:

      sudo ./latencyninja --check
      sudo ./latencyninja --clean          # asks first; --yes skips the question

Active rules, persisted rules that are valid and pending timed rollbacks are never touched. See [USAGE.md](USAGE.md#check-and-clean) for what is checked.

## Snapshots and Backups

Save the rules currently applied by Latency Ninja on all interfaces (or a single one with `--interface`):

      sudo ./latencyninja --save /root/before-test.snap

Restore them later. Interfaces in scope that have rules but weren't in the snapshot are rolled back, so restoring a snapshot taken before any rules were applied returns the system to a clean state:

      sudo ./latencyninja --restore /root/before-test.snap
      sudo ./latencyninja --restore /root/before-test.snap --interface eth0   # only eth0

Every time rules are applied, a snapshot of the previous state is written to the backup directory (`--backup`, default `/tmp`). Restoring it undoes that change; the exact command is printed after each run.

Snapshots are plain text with one argument per line and are never executed by a shell.

## Persistence

By default rules are lost at reboot or when an interface is re-created. Add `--persist` to keep them:

      sudo ./latencyninja --interface wg0 --dst_ip 10.30.0.2 --latency 50 --persist

The configuration is saved in `/etc/latencyninja/persist/` and a udev rule starts `latencyninja@<interface>.service` each time the interface appears: at boot, and whenever it is re-created (e.g. `wg-quick down/up`, NetworkManager re-creating a bond). Rules already survive a plain link down/up. The unit runs Latency Ninja from its current location, so re-run with `--persist` if you move it.

`--query` lists persisted interfaces, applying new rules with `--persist` replaces the persisted ones, and `--rollback --interface <interface>` removes them.

## Containers and Network Namespaces

Add `--container <name|id>` (Docker or Podman), `--netns <name>` or `--pid <pid>` to any command to work inside that network namespace instead of the host. Only that container's or namespace's traffic is affected:

      sudo ./latencyninja --container payments-api --show-interfaces
      sudo ./latencyninja --container payments-api --interface eth0 --dst_ip 10.88.0.1 --latency 150
      sudo ./latencyninja --container payments-api --rollback --interface eth0

`--persist` works too: rules are re-applied whenever the container restarts or the namespace is re-created. JSON files can name the target (`"container"`, `"netns"` or `"pid"`), and host snapshots include every container and namespace. See [USAGE.md](USAGE.md#containers-and-network-namespaces) for details.

## Bonded and WireGuard Interfaces

Rules can be applied to bonded and WireGuard interfaces like any other interface. On a bond, rules keep working through slave failover. On a WireGuard interface, rules apply to the traffic inside the tunnel; to affect the encrypted traffic, apply rules to the underlying interface with the peer's endpoint as `--dst_ip`.

Each interface uses its own pair of `ifb` devices (`lni-<interface>` for ingress and `lne-<interface>` for egress), so several interfaces can be shaped at the same time.

## Updating

To update Latency Ninja to the lastest version, run:

    sudo ./latencyninja --update

## Warning
- Changes made by Latency Ninja do not persist after a reboot or when an interface is re-created unless `--persist` is used.
- Latency Ninja needs the root qdisc of the interface and an ingress qdisc. Default qdiscs (`mq`, `fq_codel`, `noqueue`...) are replaced silently and come back by themselves on rollback; a qdisc you configured yourself (e.g. `htb`, `cake`, `clsact`) is replaced with a warning and is not restored by `--rollback`. `--rollback` only removes the qdiscs Latency Ninja set up.
- If applying the rules fails or is interrupted (Ctrl-C), the interface is put back as it was.

## Troubleshooting
 - Permission Denied: Make sure you're running the script with superuser privileges.
 - Interface Error: Ensure that the provided network interface exists and is up.
 - Missing Parameters: Always ensure that mandatory parameters like -i and -d are provided, except for when rolling back (using -r), which requires -i only.

## Roadmap
- **1.29** Safety and automation: JSON output for `--query` and `--show-interfaces`, default log outside `/tmp`, `--stats`.
- **1.30** IPv6 support, `--protocol tcp|udp|icmp`, port ranges and source ports (filters rewritten with `tc flower`); only redirect matching traffic.
- **1.31** More realistic conditions: per-direction values (e.g. `--egress-rate`), burst loss, correlation and jitter distributions, `--blackhole`. A `starlink` profile with asymmetric upload/download.
- **1.32** Different conditions per destination on one interface and region matrices (`--matrix regions.json`). Cloud profiles: inter-AZ latency and inter-region latency between the major regions of the main cloud providers (e.g. AWS, Azure, Google Cloud, Oracle Cloud) and between providers, usable directly or in matrices.
- **1.33** Scenarios: multi-step experiments over time (ramps, flapping links, blackout windows), including Starlink-style periodic latency spikes during satellite handovers.
- **2.0** Packaging (`make install`, .deb/.rpm), man page, bash completion, updater based on release tags, more distributions. Kubernetes: a container image usable as a sidecar (configured from a JSON ConfigMap, sharing the pod's network namespace) and pod targeting.

## Examples for Testers

[`examples/`](examples/README.md) has example Terraform (Proxmox, AWS, Azure, Google Cloud), a plain QEMU script and a Docker lab for human testers: distro VMs for the test suite, client/server labs for real-traffic tests and container targeting. They are guidance and are not run by CI.

## Contributing
We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow, tests and release process.

## License
This project is licensed under the GNU General Public License v2.0. Please refer to the LICENSE file for more details.