# Latency Ninja test lab on AWS (example Terraform)

Reference Terraform for **human testers**. It is not part of the tool and is not run by CI.

| VM | Purpose |
|----|---------|
| `ln-ubuntu`, `ln-debian`, `ln-fedora`, `ln-rocky` (`test_distros`) | Run the functional suite per distro |
| `ln-client`, `ln-server` (`enable_lab`) | Real-traffic lab in one subnet: client `10.99.1.10`, server `10.99.1.20` (listeners on 80, 443, 8080, 9090 and `iperf3 -s`) |

No router VM here: AWS does not let you override the local VPC route to steer traffic through an instance. Use the Proxmox example if you need a routed lab.

Topology diagram: [`topology.txt`](topology.txt).

## Use

```sh
cd examples/terraform/aws
cp terraform.tfvars.example terraform.tfvars   # edit
aws sso login   # or export AWS credentials
terraform init && terraform apply
terraform output public_ips
ssh ninja@<ip>
ln-test                  # pull and run the whole suite
ln-test --ref my-branch  # switch branch first
ln-test latency          # only tests whose name contains "latency"
```

First boot installs dependencies and takes a few minutes: see `/var/log/ln-provision.log`, and `/var/lib/ln-provision.done` when finished. Debian, Fedora and Rocky may reboot once to get a kernel with the netem modules.

Tear down with `terraform destroy`. VMs have public IPs, reachable only from `allowed_ssh_cidrs`; destroy the lab when you are done (it costs money while running).

## Notes

- AMIs are looked up by owner and name; pin one with `ami_overrides` if a lookup returns nothing (Fedora's name pattern is the most likely to need it).
- This has not been applied by the maintainers' automation. Report problems from the first `apply`.
