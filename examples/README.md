# Examples for testing Latency Ninja

Guidance for **human testers**: ways to get hosts, VMs and containers to try Latency Ninja on. These are not part of the tool. They are not installed, not linted and not run by CI, and the maintainers' automation has not exercised them: report problems you hit.

| Directory | What it is | Needs |
|-----------|-----------|-------|
| [`terraform/`](terraform/README.md) | Proxmox, AWS, Azure and Google Cloud: distro VMs that run the functional suite, plus a client/server lab | Terraform and an account on the platform |
| [`qemu/`](qemu/README.md) | The same on a workstation with plain QEMU, no libvirt and no root | `qemu`, `qemu-img`, an ISO tool, `ssh` |
| [`docker/`](docker/README.md) | A client/server container lab and a demo that targets a container with `--container` | A Linux host with Docker (or Podman) |

Which one for what:
- **The full functional suite (`tests/run_tests.sh`) on a given distro:** a VM (Terraform or QEMU). The suite builds network namespaces and loads kernel modules, so it needs a real kernel it may change: never a container, and never your own machine.
- **Real traffic between two hosts:** the client/server lab in Terraform or QEMU.
- **Trying `--container` and per-container conditions:** Docker.
