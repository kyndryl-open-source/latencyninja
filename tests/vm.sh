#!/usr/bin/env bash
#
# Manage Lima test VMs for Latency Ninja (run on the macOS/Linux host).
#
# Usage:
#   tests/vm.sh up [ubuntu|fedora]      Create/start the VM and install dependencies
#   tests/vm.sh test [ubuntu|fedora]    Run the test suite inside the VM
#   tests/vm.sh reboot-test [distro]    Check --persist rules survive a VM reboot
#   tests/vm.sh shell [ubuntu|fedora]   Open a shell in the repo directory inside the VM
#   tests/vm.sh down [ubuntu|fedora]    Stop the VM
#   tests/vm.sh destroy [ubuntu|fedora] Delete the VM
#
# The repository is mounted read-only inside the VM at the same path as on the host,
# so edits on the host are picked up immediately.

set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
action="${1:-}"
distro="${2:-ubuntu}"
vm_name="ln-${distro}"

case "$distro" in
    ubuntu) template="template:ubuntu-lts" ;;
    fedora) template="template:fedora" ;;
    *) echo "Unsupported distro: $distro (use ubuntu or fedora)"; exit 1 ;;
esac

command -v limactl >/dev/null || { echo "limactl not found. Install with: brew install lima"; exit 1; }

vm_exists() { limactl list -q 2>/dev/null | grep -qx "$vm_name"; }

provision() {
    case "$distro" in
        ubuntu)
            limactl shell "$vm_name" -- sudo bash -c '
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                apt-get install -y -qq kmod iproute2 inetutils-ping curl jq git python3 wireguard-tools podman >/dev/null
                modprobe ifb && modprobe sch_netem || apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null'
            ;;
        fedora)
            limactl shell "$vm_name" -- sudo bash -c '
                dnf install -y -q kmod iproute iproute-tc iputils curl jq git python3 wireguard-tools podman kernel-modules-extra-$(uname -r) || \
                dnf install -y -q kmod iproute iproute-tc iputils curl jq git python3 wireguard-tools podman kernel-modules-extra'
            ;;
    esac
}

case "$action" in
    up)
        if vm_exists; then
            limactl start "$vm_name" --tty=false
        else
            limactl start --name="$vm_name" --tty=false --cpus=2 --memory=2 --disk=15 \
                --set ".mounts=[{\"location\":\"$repo_dir\",\"writable\":false}]" \
                "$template"
        fi
        provision
        echo "VM $vm_name is ready. Run: tests/vm.sh test $distro"
        ;;
    test)
        limactl shell --workdir "$repo_dir" "$vm_name" -- sudo bash tests/run_tests.sh "${@:3}"
        ;;
    reboot-test)
        limactl shell --workdir "$repo_dir" "$vm_name" -- sudo bash tests/reboot_test.sh prepare
        echo "Rebooting $vm_name..."
        limactl stop "$vm_name" >/dev/null 2>&1
        limactl start "$vm_name" --tty=false >/dev/null 2>&1
        status=0
        limactl shell --workdir "$repo_dir" "$vm_name" -- sudo bash tests/reboot_test.sh verify || status=1
        limactl shell --workdir "$repo_dir" "$vm_name" -- sudo bash tests/reboot_test.sh cleanup
        exit "$status"
        ;;
    shell)
        limactl shell --workdir "$repo_dir" "$vm_name"
        ;;
    down)
        limactl stop "$vm_name"
        ;;
    destroy)
        limactl delete -f "$vm_name"
        ;;
    *)
        sed -n '3,16p' "$0"
        exit 1
        ;;
esac
