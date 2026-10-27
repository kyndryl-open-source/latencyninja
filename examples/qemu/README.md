# Plain QEMU lab

Test VMs on a workstation with plain QEMU: no libvirt, no root, no bridges. Linux (KVM) and macOS (HVF), x86_64 and Apple Silicon / arm64. Example for human testers; not run by CI.

```sh
brew install qemu          # or: apt install qemu-system qemu-utils genisoimage
examples/qemu/qemu-lab.sh up ubuntu fedora      # distro VMs: ubuntu debian fedora rocky
examples/qemu/qemu-lab.sh up lab                # ln-client + ln-server
examples/qemu/qemu-lab.sh wait                  # first boot installs dependencies (a few minutes)
examples/qemu/qemu-lab.sh test ubuntu           # run the functional suite in ln-ubuntu
examples/qemu/qemu-lab.sh test ubuntu latency   # only tests whose name contains "latency"
examples/qemu/qemu-lab.sh ssh client
examples/qemu/qemu-lab.sh status | down | destroy
```

- **Same provisioning as the Terraform examples:** the VMs use `../terraform/common/cloud-init/provision.sh`, so `ln-test`, `ln-test --ref <branch>`, the listeners on 80, 443, 8080, 9090 and `iperf3 -s` work the same way.
- **Networking:** each VM has a user-mode NIC with SSH forwarded to `127.0.0.1` (ports 2201-2204 for the distros, 2211 client, 2212 server). The lab pair also has a private link between them: client `10.99.1.10`, server `10.99.1.20` (no router, as in the cloud examples).
- **Images** are downloaded once into `~/.cache/latencyninja-qemu` (override with `LN_QEMU_DIR`) and each VM is a copy-on-write overlay. Override a URL with `LN_IMAGE_FEDORA=...` if a mirror moves.
- **Architecture:** the guest matches the host, since emulating another architecture is far too slow to be useful. On arm64 hosts QEMU needs UEFI firmware: Homebrew's qemu ships it, on Debian/Ubuntu install `qemu-efi-aarch64`.
- Needs an ISO tool for the cloud-init seed: `cloud-localds`, `genisoimage`, `mkisofs`, `xorriso` or macOS's `hdiutil`.
- Without KVM or HVF the script falls back to TCG and warns: the suite is too slow to be practical that way.
