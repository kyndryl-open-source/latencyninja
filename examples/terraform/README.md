# Terraform examples

Reference Terraform that human testers can use to build VMs for trying Latency Ninja on real hosts. See [`../README.md`](../README.md) for the other examples (plain QEMU, Docker) and what "example" means here.

| Directory | Platform | Distros | Lab |
|-----------|----------|---------|-----|
| [`proxmox/`](proxmox/README.md) | Proxmox VE (VMs) | Ubuntu, Debian, Fedora, Rocky | client, server and an optional router across two segments |
| [`aws/`](aws/README.md) | AWS EC2 | Ubuntu, Debian, Fedora, Rocky | client and server in one subnet |
| [`azure/`](azure/README.md) | Azure VMs | Ubuntu, Debian, Rocky | client and server in one subnet |
| [`gcp/`](gcp/README.md) | Google Compute Engine | Ubuntu, Debian, Rocky | client and server in one subnet |

Each one builds:
- **Distro VMs** that run the functional suite (`tests/run_tests.sh`), which builds its own network namespaces. Pick them with `test_distros`.
- **A client/server lab** for real-traffic tests: apply rules on the client and measure to the server with `ping`, `curl` and `iperf3`. The server listens on 80, 443, 8080 and 9090 and runs `iperf3 -s`.

`common/cloud-init/` holds the provisioning the four share. On first boot it installs the dependencies, loads `ifb`, `sch_netem`, `bonding` and `wireguard` (switching to a full kernel and rebooting once where the cloud kernel lacks them), and checks out the repo into `/opt/latencyninja`. On each VM, `ln-test` pulls and runs the suite, `ln-test --ref <branch>` switches branch first, and `ln-test <filter>` runs a subset.

Cloud VMs cost money while they run and have public IPs limited to `allowed_ssh_cidrs`: run `terraform destroy` when you are done.
