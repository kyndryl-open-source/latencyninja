# Latency Ninja test lab on Proxmox (example Terraform)

Terraform (bpg/proxmox provider) that builds VMs for exercising every Latency Ninja feature.

| VM | Purpose |
|----|---------|
| `ln-ubuntu`, `ln-debian`, `ln-fedora`, `ln-rocky` (pick with `test_distros`) | Run the functional suite (`tests/run_tests.sh`) per distro. The suite builds its own network namespaces, so each VM only needs a real kernel with `ifb`, `sch_netem`, `bonding` and `wireguard`. |
| `ln-client`, `ln-server` (+ `ln-router` with two lab bridges) | Real-traffic lab: apply rules on the client or router, measure to the server with `ping`, `curl` and `iperf3`. The server listens on 80, 443, 8080, 9090 and runs `iperf3 -s`. |

Lab addressing with `lab_bridge_a`/`lab_bridge_b` set: client `10.99.1.10`, router `10.99.1.1` / `10.99.2.1`, server `10.99.2.20`. Without them, client and server share `bridge` (DHCP) and there is no router. Every VM also gets a DHCP NIC on `bridge` for SSH.

Topology diagram: [`topology.txt`](topology.txt).

## Proxmox prerequisites

- API token with VM, datastore and SDN-free permissions (a `PVEVMAdmin` + `PVEDatastoreAdmin` role on `/` is enough).
- `image_datastore` allows content type **import** (PVE 8.4+); `snippet_datastore` allows **snippets** (Datacenter > Storage > Edit > Content).
- Your SSH key is in the node's `authorized_keys` (the provider uploads snippets over SSH).
- Lab bridges, if used, already exist on the node.

## Use

```sh
cd examples/terraform/proxmox
cp terraform.tfvars.example terraform.tfvars   # edit
export TF_VAR_proxmox_api_token='user@pve!terraform=...'
terraform init && terraform apply
terraform output management_ips                # once the guest agent is up
ssh ninja@<ip>
ln-test                  # pull and run the whole suite
ln-test --ref my-branch  # switch branch first
ln-test latency          # only tests whose name contains "latency"
```

First boot installs dependencies and takes a few minutes; progress is in `/var/log/ln-provision.log` and finishes with `/var/lib/ln-provision.done`. Rocky/Fedora may need one reboot if `kernel-modules-extra` landed for a newer kernel than the one running.

Tear down with `terraform destroy`. VM IDs start at `vm_id_start` (default 9100) and stay stable when you change `test_distros`.

## Notes

- Image URLs live in `image_urls`; override one if a mirror moves (Fedora's file name is version-specific).
- For human testers: this lab is not exercised by CI or by automated review, and has not been applied to a real node. Report problems with the first `apply`.
- CI does not lint or run anything under `examples/`. The version/CHANGELOG gate applies to every PR to `main`, whatever files change.
- Sibling examples for AWS, Azure and Google Cloud live next to this one and share `../common/cloud-init/`. This is the only one with a routed lab (client, router, server); vSphere is not written yet.
