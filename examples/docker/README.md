# Docker lab

Two containers on a private network, and a walk-through that applies Latency Ninja rules to one of them from the host. Example for human testers; not run by CI.

| Container | Address | Role |
|-----------|---------|------|
| `ln-server` | `10.99.1.20` | HTTP listeners on 80, 443, 8080, 9090 and `iperf3 -s` |
| `ln-client` | `10.99.1.10` | Where you measure from (`ping`, `curl`, `iperf3`) |

Latency Ninja is not inside the containers. It runs on the host and enters the container's network namespace with `--container`, so only that container's traffic changes.

## Requirements

- A **Linux host** with Docker (or Podman), root access, and Latency Ninja's own requirements (`tc`, the `ifb` and `sch_netem` modules). Docker Desktop on macOS or Windows does not work: the containers live in a VM, not on the host Latency Ninja runs on.
- Run it on a throwaway machine or one of the VMs from `../terraform` or `../qemu`.

## Run

```sh
sudo examples/docker/demo.sh          # build, start, walk through, roll back
sudo examples/docker/demo.sh down     # remove the containers
```

The demo shows `--show-interfaces`, latency/jitter/loss, a single destination port, a profile, a bandwidth limit measured with `iperf3`, a timed `--duration` rollback, and `--check`. It rolls everything back at the end and when interrupted.

By hand:

```sh
docker compose -f examples/docker/compose.yaml up -d --build
docker exec ln-client ping -c 5 10.99.1.20
sudo ./latencyninja --container ln-client --interface eth0 --dst_ip 10.99.1.20 --latency 100
docker exec ln-client ping -c 5 10.99.1.20
sudo ./latencyninja --container ln-client --interface eth0 --rollback
```

## What this does not cover

- **The functional suite** (`tests/run_tests.sh`): it creates namespaces, bonds and WireGuard interfaces and installs systemd units, so it needs a real kernel and distro: use a VM.
- **A Latency Ninja container image / Kubernetes sidecar:** planned for 2.0, not here.
