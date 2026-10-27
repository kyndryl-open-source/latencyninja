# Latency Ninja test lab on Google Cloud (example Terraform)

Reference Terraform for **human testers**. It is not part of the tool and is not run by CI.

| VM | Purpose |
|----|---------|
| `ln-ubuntu`, `ln-debian`, `ln-rocky` (`test_distros`) | Run the functional suite per distro. Fedora has no public GCE image; use Proxmox or AWS for it |
| `ln-client`, `ln-server` (`enable_lab`) | Real-traffic lab in one subnet: client `10.99.1.10`, server `10.99.1.20` (listeners on 80, 443, 8080, 9090 and `iperf3 -s`) |

No router VM here; use the Proxmox example for a routed lab.

Topology diagram: [`topology.txt`](topology.txt).

## Use

```sh
cd examples/terraform/gcp
cp terraform.tfvars.example terraform.tfvars   # edit
gcloud auth application-default login
terraform init && terraform apply
terraform output public_ips
ssh ninja@<ip>
ln-test                  # pull and run the whole suite
ln-test --ref my-branch  # switch branch first
ln-test latency          # only tests whose name contains "latency"
```

Provisioning runs from the GCE startup script (not cloud-init, which not every GCE image uses) and takes a few minutes: see `/var/log/ln-provision.log`, and `/var/lib/ln-provision.done` when finished. Debian and Rocky may reboot once to get a kernel with the netem modules.

Tear down with `terraform destroy`. VMs have public IPs, reachable only from `allowed_ssh_cidrs`.

## Notes

- OS Login is turned off so the SSH keys from `ssh_public_keys` work. Turn it back on if your organisation requires it and manage access through IAM instead.
- This has not been applied by the maintainers' automation. Report problems from the first `apply`.
