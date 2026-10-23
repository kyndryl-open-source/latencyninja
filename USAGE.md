# Latency Ninja Usage Guide

Detailed examples of every Latency Ninja feature. For installation and an overview, see the [README](README.md).

- [Basics](#basics)
- [Finding the right interface](#finding-the-right-interface)
- [Latency and jitter](#latency-and-jitter)
- [Packet loss, duplication, corruption and reordering](#packet-loss-duplication-corruption-and-reordering)
- [Bandwidth limits](#bandwidth-limits)
- [Combining conditions](#combining-conditions)
- [Direction: ingress, egress or both](#direction-ingress-egress-or-both)
- [Choosing which traffic is affected](#choosing-which-traffic-is-affected)
- [Profiles](#profiles)
- [JSON files](#json-files)
- [Checking what is applied](#checking-what-is-applied)
- [Rolling back](#rolling-back)
- [Timed rollback](#timed-rollback)
- [Snapshots and backups](#snapshots-and-backups)
- [Persistence across reboots and interface restarts](#persistence-across-reboots-and-interface-restarts)
- [Several interfaces at once](#several-interfaces-at-once)
- [Bonded interfaces](#bonded-interfaces)
- [WireGuard interfaces](#wireguard-interfaces)
- [Containers and network namespaces](#containers-and-network-namespaces)
- [Logs, backups and debugging](#logs-backups-and-debugging)
- [Updating](#updating)
- [Recipes](#recipes)
- [Troubleshooting](#troubleshooting)

## Basics

Latency Ninja must run as root (`--show-interfaces` is the only exception). It can be run from any directory:

    sudo ./latencyninja --interface eth0 --dst_ip 192.168.100.123 --latency 50
    sudo /opt/latencyninja/latencyninja -i eth0 -d 192.168.100.123 -l 50      # same, short options

Every option has a long form; the most common also have a short form:

| Short | Long | Short | Long |
|---|---|---|---|
| `-i` | `--interface` | `-x` | `--packet_loss` |
| `-d` | `--dst_ip` | `-y` | `--duplicate` |
| `-s` | `--src_ip` | `-z` | `--corrupt` |
| `-w` | `--direction` | `-k` | `--reorder` |
| `-l` | `--latency` | `-b` | `--rate` |
| `-j` | `--jitter` | `-p` | `--profile` |
| `-t` | `--duration` | `-q` | `--query` |
| `-r` | `--rollback` | `-v` | `--version` |

Applying new rules to an interface replaces the rules already on it. Each run prints what was applied, how to check and roll it back, and where the backup and log were written:

    Applied network perturbations with the following parameters:
      - Interface: eth0
      - Source IP/Network: 192.168.100.10:0
      - Destination IP/Network: 192.168.100.123:0
      - Direction: both
      - Latency: 50 ms

    To validate, run: sudo ./latencyninja --query
    To rollback, run: sudo ./latencyninja --rollback --interface eth0

    Backup saved to: /tmp/latencyninja_tc_backup_20261023_165052_375560 (restore with: sudo ./latencyninja --restore /tmp/latencyninja_tc_backup_20261023_165052_375560)
    Log updated at: /tmp/latencyninja.log

## Finding the right interface

List the interfaces rules can be applied to, with their type, IPv4 address and current Latency Ninja state. It also works without `sudo`, but then doesn't show persistence and timed rollbacks:

    sudo ./latencyninja --show-interfaces

    INTERFACE        STATE    TYPE                           IPV4                 LATENCY NINJA
    eth0             UP       ethernet                       192.168.5.15/24      -
    bond0            UP       bond                           10.40.0.1/24         rules (both), persisted
    lnb0             UP       veth (bond member of bond0)    -                    -
    wg0              UNKNOWN  wireguard                      10.30.0.1/24         rules (egress), rollback in 9m 12s

Apply rules to the interface that carries the traffic and has an IPv4 address (for a bond, the bond itself rather than its members).

## Latency and jitter

Add 50 ms of round-trip latency to traffic with one host:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 50

Add jitter (variation) on top of the latency. Jitter requires latency:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 100 --jitter 20

Values can be decimals:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 2.5 --jitter 0.5

Latency and jitter are round-trip values: with the default direction (`both`), half is applied to incoming and half to outgoing traffic, so a ping shows the full value.

## Packet loss, duplication, corruption and reordering

All four are percentages and accept decimals:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --packet_loss 2        # drop 2% of packets
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --duplicate 1          # duplicate 1% of packets
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --corrupt 0.1          # flip a bit in 0.1% of packets
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 50 --reorder 5   # send 5% of packets out of order

Reordering works by sending some packets without the delay, so combine it with `--latency`.

Drop everything to a destination (simulate an unreachable dependency):

    sudo ./latencyninja -i eth0 -d 10.0.5.20 --packet_loss 100

## Bandwidth limits

Limit the bandwidth of the targeted traffic. Units are `bit`, `kbit`, `mbit`, `gbit` (bits per second) or `bps`, `kbps`, `mbps`, `gbps` (bytes per second):

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --rate 2mbit
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --rate 512kbit
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --rate 1mbps          # 1 megabyte/s = 8 Mbit/s

The rate applies to each direction separately (it isn't split like latency). To limit only uploads from this host:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --rate 2mbit --direction egress

## Combining conditions

All conditions can be combined in a single run:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 \
        --latency 120 --jitter 15 --packet_loss 1 --duplicate 0.2 --corrupt 0.05 --reorder 2 --rate 10mbit

## Direction: ingress, egress or both

| `--direction` | Affects | Latency/jitter applied |
|---|---|---|
| `both` (default) | incoming and outgoing traffic | half in each direction |
| `egress` | traffic leaving this host | full value |
| `ingress` | traffic arriving at this host | full value |

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 100 --direction egress
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 100 --direction ingress

In all three cases a ping to the destination shows about 100 ms more.

## Choosing which traffic is affected

Only traffic matching the destinations (and sources) you give is affected; everything else on the interface is untouched.

A single host, a host and port, or several ports of one host (separated by `~`):

    sudo ./latencyninja -i eth0 -d 192.168.100.123 -l 50
    sudo ./latencyninja -i eth0 -d 192.168.100.123:443 -l 50
    sudo ./latencyninja -i eth0 -d 192.168.100.123:80~443~8080 -l 50

Several destinations and subnets, separated by commas, each with optional ports:

    sudo ./latencyninja -i eth0 -d 192.168.100.123,192.168.100.124:5432,10.20.0.0/16:80~443 -l 50

Ports are matched as the remote port: outgoing packets to that port and replies from it.

By default the source is the interface's (first) IPv4 address. Use `--src_ip` to only affect traffic from specific local addresses or networks:

    sudo ./latencyninja -i eth0 -s 192.168.100.10 -d 192.168.100.123 -l 50

If you give only `--src_ip`, the destination defaults to this host and the perspective is reversed: the rules affect traffic between this host and the given addresses. This is handy to slow down specific clients:

    sudo ./latencyninja -i eth0 -s 192.168.100.200,192.168.100.201 -l 300

## Profiles

Profiles apply a realistic combination of conditions in one option:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --profile 4g
    sudo ./latencyninja -i eth0 -d 192.168.100.123 -p satellite

List them with their values:

    sudo ./latencyninja --profiles

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

Options given explicitly override the profile's values; the others still come from the profile:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --profile 4g --latency 150     # 4G, but with 150 ms
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --profile 3g --rate 500kbit    # a congested 3G link

Create your own profile as a JSON file in `/etc/latencyninja/profiles/` (the file name is the profile name). It uses the same keys as `--json` plus a description:

    sudo mkdir -p /etc/latencyninja/profiles
    sudo tee /etc/latencyninja/profiles/branch-office.json <<'EOF'
    { "description": "Branch office VPN", "latency": "45", "jitter": "8", "packet_loss": "0.3", "rate": "50mbit" }
    EOF
    sudo ./latencyninja -i eth0 -d 10.0.0.0/8 --profile branch-office

A custom profile with the same name as a built-in one replaces it. Unknown keys in a profile are rejected, so a typo doesn't silently drop a value. Snapshots and persisted rules store the resolved values, so editing a profile later doesn't change rules that were saved with it.

## JSON files

Every option that applies rules can come from a JSON file, including the target container or namespace, persistence, and the backup and log locations:

    {
        "container": "payments-api",
        "interface": "eth0",
        "dst_ip": ["10.88.0.1", "10.20.0.0/16:80~443"],
        "direction": "both",
        "profile": "4g",
        "latency": 150,
        "packet_loss": "0.5",
        "persist": true,
        "logging": "/var/log/latencyninja.log"
    }

    sudo ./latencyninja --json experiment.json

| Key | Value | Same as |
|---|---|---|
| `interface` | string | `--interface` |
| `src_ip`, `dst_ip` | string (comma-separated) or array of strings | `--src_ip`, `--dst_ip` |
| `direction` | `"ingress"`, `"egress"` or `"both"` | `--direction` |
| `latency`, `jitter` | number or string (ms) | `--latency`, `--jitter` |
| `packet_loss`, `duplicate`, `corrupt`, `reorder` | number or string (%) | `--packet_loss`, `--duplicate`, `--corrupt`, `--reorder` |
| `rate` | string with unit, e.g. `"2mbit"` | `--rate` |
| `profile` | profile name | `--profile` |
| `duration` | string, e.g. `"15m"`, or number of seconds | `--duration` |
| `persist` | `true` or `false` | `--persist` |
| `backup`, `logging` | path | `--backup`, `--logging` |
| `container`, `netns`, `pid` | name, name or process ID (only one of them) | `--container`, `--netns`, `--pid` |

Rules:

- Every key is optional, as long as the interface and a destination or source are given in the file or on the command line.
- Values in the file override the same options given on the command line. The exception is the target: giving a container, namespace or process both in the file and on the command line is an error.
- A profile named in the file only fills in values that aren't set.
- Unknown keys (e.g. a typo like `latncy`), values of the wrong type and invalid JSON are rejected before anything is applied.

## Checking what is applied

    sudo ./latencyninja --query

`--query` shows every device's filters and netem settings, followed by persisted interfaces and pending timed rollbacks. Rules for an interface appear on its ifb devices, `lni-<interface>` (ingress) and `lne-<interface>` (egress):

    Device: lni-eth0
    src_ip: 192.168.100.123/32, src_port: 443, dst_ip: 192.168.100.10/32, dst_port: 0
    netem: delay 40ms jitter 5ms loss 0.5%

    Device: lne-eth0
    src_ip: 192.168.100.10/32, src_port: 0, dst_ip: 192.168.100.123/32, dst_port: 443
    netem: delay 40ms jitter 5ms loss 0.5%

    Persisted interfaces: none
    Scheduled rollbacks: eth0 in 9m 58s

`--show-interfaces` gives a shorter per-interface summary.

## Rolling back

Remove all Latency Ninja rules from an interface (and its persisted rules and pending timed rollback):

    sudo ./latencyninja --rollback --interface eth0

Other interfaces are not affected.

## Timed rollback

Apply rules for a limited time; they are removed automatically afterwards:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 200 --duration 15m

Durations accept `s`, `m`, `h` and `d` (no unit means seconds): `90`, `30s`, `10m`, `2h`, `1d`.

When the time is up, the interface goes back to how it was just before: if it had no rules they are removed, and if it had rules they are re-applied. For example, to add a 5-minute packet loss spike on top of a permanent latency:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 50                       # baseline
    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 50 --packet_loss 20 -t 5m # spike, back to baseline after 5 minutes

`--query` and `--show-interfaces` show the time left. To end earlier, roll back; to keep the current rules and cancel the timer, apply them again without `--duration`.

Timed rollback uses a systemd timer, so it requires systemd and can't be combined with `--persist`. Timers don't survive a reboot (neither do non-persisted rules).

On remote machines, `--duration` is a good safety net: if a rule cuts off your SSH session, it is removed automatically.

## Snapshots and backups

Save the current Latency Ninja rules of all interfaces to a file:

    sudo ./latencyninja --save /root/before-experiment.snap

    Snapshot saved to: /root/before-experiment.snap
    Interfaces with rules: eth0 bond0

On the host, a snapshot of everything also includes the rules of every container and namespace, and restoring it re-enters each one (containers by name, so they can have been restarted in between):

    Snapshot saved to: /root/before-experiment.snap
    Interfaces with rules: eth0 bond0 eth0@container:payments-api lnpeer0@netns:blue

Save only one interface (of the host, or of a container with `--container`):

    sudo ./latencyninja --save /root/eth0.snap --interface eth0
    sudo ./latencyninja --container payments-api --save /root/payments.snap

Restore a snapshot. Interfaces in scope that have rules but weren't in the snapshot are rolled back, so restoring a snapshot taken with no rules returns everything to a clean state:

    sudo ./latencyninja --restore /root/before-experiment.snap
    sudo ./latencyninja --restore /root/before-experiment.snap --interface eth0   # only eth0

Every time rules are applied, a snapshot of the previous state is written to the backup directory. Restoring it undoes that change; the exact command is printed after each run:

    sudo ./latencyninja --restore /tmp/latencyninja_tc_backup_20261023_165052_375560

Snapshots are plain text with one argument per line. They are never executed by a shell, and only rule options are accepted when restoring. The end of the file contains a human-readable dump of all tc rules at the time it was taken.

## Persistence across reboots and interface restarts

By default, rules are lost at reboot and when an interface is re-created. Add `--persist` to keep them:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 --latency 50 --persist

    Persisted: rules for eth0 will be re-applied at boot and when the interface is re-created (latencyninja@eth0.service).

The rules are re-applied at boot and whenever the interface appears again, for example after `wg-quick down wg0 && wg-quick up wg0` or when NetworkManager re-creates a bond. A plain `ip link set eth0 down/up` doesn't remove rules in the first place.

- Apply new rules with `--persist` to replace the persisted ones.
- Applying new rules without `--persist` changes them until the next reboot and prints a note that different rules are persisted.
- `--rollback --interface eth0` removes the persisted rules too.
- `--query` lists persisted interfaces; `--show-interfaces` marks them.

Persistence uses a udev rule and a systemd unit that run Latency Ninja from its current location, so re-run with `--persist` if you move it. It requires systemd.

### Persistence in containers and namespaces

`--persist` also works with `--container` and `--netns`:

    sudo ./latencyninja --container payments-api -i eth0 -d 10.88.0.1 --latency 150 --persist
    sudo ./latencyninja --netns blue -i veth-blue -d 10.0.0.1 --rate 2mbit --persist

The rules are re-applied whenever the container restarts (including after a reboot, when it is started again) or the namespace or interface is re-created. Containers are tracked by name, so this also covers containers re-created with the same name, e.g. by `docker compose down && docker compose up`. A background service, `latencyninja-namespaces.service`, checks every few seconds; it runs only while some container or namespace has persisted rules.

Like on the host, rules you remove or change in a running container (with `--rollback --keep-persist`, `--restore` or new rules without `--persist`) aren't overridden until it restarts. `--rollback` removes the persisted rules.

Processes (`--pid`) can't have persisted rules, because a process doesn't survive a restart; use `--container` or `--netns` instead. Persisted rules of containers and namespaces appear in `--query` on the host as `<interface>@container:<name>` or `<interface>@netns:<name>`.

## Several interfaces at once

Each interface has its own rules and ifb devices, so they can be shaped independently:

    sudo ./latencyninja -i eth0 -d 10.0.0.0/8 --profile transatlantic
    sudo ./latencyninja -i eth1 -d 172.16.5.10 --rate 5mbit
    sudo ./latencyninja -i wg0 -d 10.30.0.2 --packet_loss 2 --duration 30m

    sudo ./latencyninja --rollback --interface eth1    # eth0 and wg0 keep their rules

## Bonded interfaces

Apply rules to the bond, not to its members. They keep working when the bond fails over to another member:

    sudo ./latencyninja -i bond0 -d 10.40.0.2 --latency 60
    sudo ./latencyninja -i bond0 -d 10.40.0.2:5432 --latency 20 --packet_loss 0.5 --persist

## WireGuard interfaces

Rules on a WireGuard interface affect the traffic inside the tunnel:

    sudo ./latencyninja -i wg0 -d 10.30.0.2 --latency 80
    sudo ./latencyninja -i wg0 -d 10.30.0.0/24:443 --rate 2mbit --direction egress

To affect the encrypted tunnel traffic itself (all of it, as seen by the network), apply rules to the underlying interface with the peer's endpoint as destination, for example the UDP port of the endpoint:

    sudo ./latencyninja -i eth0 -d 203.0.113.7:51820 --latency 80

## Containers and network namespaces

Apply rules inside a container or network namespace instead of the whole host. Only that container's traffic is affected, and the host's interfaces are untouched.

Docker or Podman container, by name or ID (the interface is the container's, usually `eth0`):

    sudo ./latencyninja --container payments-api -i eth0 -d 10.88.0.1 --latency 150
    sudo ./latencyninja --container 3f2a9c1b7d4e -i eth0 -d 172.17.0.0/16 --profile 3g

Named network namespace (see `ip netns list`) or the namespace of a process:

    sudo ./latencyninja --netns blue -i veth-blue -d 10.0.0.1 --latency 50
    sudo ./latencyninja --pid 41237 -i eth0 -d 10.0.0.1 --packet_loss 5

The namespace option works with every other option:

    sudo ./latencyninja --container payments-api --show-interfaces
    sudo ./latencyninja --container payments-api --query
    sudo ./latencyninja --container payments-api -i eth0 -d 10.88.0.1 -l 300 --duration 10m
    sudo ./latencyninja --container payments-api --save /root/payments.snap
    sudo ./latencyninja --container payments-api --restore /root/payments.snap
    sudo ./latencyninja --container payments-api --rollback --interface eth0

Notes:

- State and timed rollbacks are kept per network namespace, even if it is reached in different ways (e.g. `--container` and `--pid` of a process inside it). A target that turns out to be the host's own namespace (e.g. `--pid` of a host process) is treated as the host.
- A snapshot taken with `--container` (or `--netns`, `--pid`) contains only that container and must be restored with the same option. A snapshot taken on the host without these options includes all containers and namespaces; see [Snapshots and backups](#snapshots-and-backups).
- `--persist` works with `--container` and `--netns`; see [Persistence in containers and namespaces](#persistence-in-containers-and-namespaces).
- To find what to target, `--show-interfaces` inside the container shows its interfaces and addresses. The container's gateway (e.g. `10.88.0.1` for Podman, `172.17.0.1` for Docker) is the destination for traffic between the container and the host or the outside world.

## Logs, backups and debugging

Choose where backups and the execution log are written (defaults: `/tmp` and `/tmp/latencyninja.log`):

    sudo ./latencyninja -i eth0 -d 192.168.100.123 -l 50 --backup /var/backups/latencyninja --logging /var/log/latencyninja.log

The log records every applied configuration with its parameters, the resulting netem settings and, if used, the profile, duration and namespace.

Print detailed error information and variables when something fails:

    sudo ./latencyninja -i eth0 -d 192.168.100.123 -l 50 --debug

## Updating

    sudo ./latencyninja --update

The updater compares your version with the latest release on GitHub and, if you agree, pulls it with git (as the user who ran `sudo`, to keep file ownership).

## Recipes

**Simulate a cross-region database replica** (all traffic to the replica network gets transatlantic latency, permanently):

    sudo ./latencyninja -i eth0 -d 10.50.0.0/16:5432 --profile transatlantic --persist

**Test client timeouts and retries** with a 10-minute window of heavy loss, then automatic recovery:

    sudo ./latencyninja -i eth0 -d 10.0.5.20:443 --packet_loss 30 --duration 10m

**Make a dependency unreachable** for 2 minutes:

    sudo ./latencyninja -i eth0 -d 10.0.5.20 --packet_loss 100 --duration 2m

**Slow down one microservice** without touching the others on the same host:

    sudo ./latencyninja --container checkout -i eth0 -d 172.17.0.0/16 --latency 250 --jitter 50 --duration 15m

**Emulate mobile users** reaching a web server (traffic from a test client subnet):

    sudo ./latencyninja -i eth0 -s 192.168.50.0/24 --profile 3g

**Run an experiment and put everything back exactly as it was:**

    sudo ./latencyninja --save /root/before.snap
    sudo ./latencyninja -i eth0 -d 10.0.0.0/8 --profile satellite
    sudo ./latencyninja -i bond0 -d 10.40.0.0/24 --rate 1mbit
    # ... run the experiment ...
    sudo ./latencyninja --restore /root/before.snap

## Troubleshooting

- **"This script must be run as root"**: use `sudo`. Only `--show-interfaces` works without root.
- **"Invalid interface"**: check the name with `--show-interfaces` (or inside the container with `--container <name> --show-interfaces`).
- **"Interface ... has no IPv4 address"**: bond members and some tunnel interfaces have no address; target the bond or the interface that has one, or give both `--src_ip` and `--dst_ip`.
- **Nothing seems to happen**: check that the destination matches the traffic (`--query` shows the filters), and that ports are the remote side's ports.
- **Missing packages**: Latency Ninja offers to install them; see the README for the list per distribution.
- **SSH session lost after applying rules**: if you used `--duration`, wait for the automatic rollback; otherwise roll back from the console.
