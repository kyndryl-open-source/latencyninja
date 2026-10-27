#!/usr/bin/env bash
#
# Test VMs for Latency Ninja with plain QEMU: no libvirt, no root, Linux or macOS (KVM / HVF).
# Example for human testers; not run by CI.
#
# Usage:
#   qemu-lab.sh up [distro...|lab]   Create and start VMs (default: ubuntu). distro: ubuntu debian fedora rocky
#                                    lab = ln-client + ln-server joined by a private link (10.99.1.10 / 10.99.1.20)
#   qemu-lab.sh wait [vm...]         Wait until first-boot provisioning has finished
#   qemu-lab.sh status               List VMs, state and SSH ports
#   qemu-lab.sh ssh <vm> [cmd...]    SSH into a VM (vm: ubuntu, client, ... or the full ln-* name)
#   qemu-lab.sh test <vm> [filter]   Run the functional suite in a VM (ln-test)
#   qemu-lab.sh down [vm...]         Stop VMs (disks are kept)
#   qemu-lab.sh destroy [vm...]      Stop and delete VMs (downloaded images are kept)
#
# Environment:
#   LN_QEMU_DIR      state directory (default ~/.cache/latencyninja-qemu)
#   LN_SSH_PUBKEY    public key file to inject (default: ~/.ssh/id_ed25519.pub, then id_rsa.pub)
#   LN_REPO_REF      branch or tag the VMs check out (default main)
#   LN_IMAGE_<DISTRO> override a cloud image URL, e.g. LN_IMAGE_FEDORA=https://...
#   LN_MEMORY / LN_CPUS / LN_DISK   per-VM sizing (default 2048 MB / 2 / 20G)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
provision="$here/../terraform/common/cloud-init/provision.sh"
state="${LN_QEMU_DIR:-$HOME/.cache/latencyninja-qemu}"
user="ninja"
repo_url="${LN_REPO_URL:-https://github.com/kyndryl-open-source/latencyninja.git}"
repo_ref="${LN_REPO_REF:-main}"
memory="${LN_MEMORY:-2048}" cpus="${LN_CPUS:-2}" disk="${LN_DISK:-20G}"
lab_link_port=12399

die() { echo "Error: $*" >&2; exit 1; }

# ---------- host detection ----------

case "$(uname -m)" in
    x86_64|amd64) arch=x86_64; qemu=qemu-system-x86_64; img_arch_ubuntu=amd64; img_arch_debian=amd64 ;;
    arm64|aarch64) arch=aarch64; qemu=qemu-system-aarch64; img_arch_ubuntu=arm64; img_arch_debian=arm64 ;;
    *) die "unsupported host architecture $(uname -m)" ;;
esac

if [ "$(uname -s)" = Darwin ]; then accel=hvf
elif [ -r /dev/kvm ] && [ -w /dev/kvm ]; then accel=kvm
else accel=tcg; echo "Warning: no KVM/HVF acceleration, VMs will be very slow" >&2
fi

image_url() {
    local override
    override="LN_IMAGE_$(tr a-z A-Z <<< "$1")"
    [ -n "${!override:-}" ] && { echo "${!override}"; return; }
    case "$1" in
        ubuntu) echo "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-$img_arch_ubuntu.img" ;;
        debian) echo "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-$img_arch_debian.qcow2" ;;
        fedora) echo "https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/$arch/images/Fedora-Cloud-Base-Generic-42-1.1.$arch.qcow2" ;;
        rocky)  echo "https://dl.rockylinux.org/pub/rocky/9/images/$arch/Rocky-9-GenericCloud-Base.latest.$arch.qcow2" ;;
    esac
}

family_of() { case "$1" in ubuntu|debian|client|server) echo debian ;; *) echo rhel ;; esac; }
base_of() { case "$1" in client|server) echo ubuntu ;; *) echo "$1" ;; esac; }
ssh_port_of() { case "$1" in ubuntu) echo 2201 ;; debian) echo 2202 ;; fedora) echo 2203 ;; rocky) echo 2204 ;; client) echo 2211 ;; server) echo 2212 ;; esac; }
lab_ip_of() { case "$1" in client) echo 10.99.1.10 ;; server) echo 10.99.1.20 ;; esac; }
lab_mac_of() { case "$1" in client) echo 52:54:00:99:01:10 ;; server) echo 52:54:00:99:01:20 ;; esac; }
role_of() { case "$1" in client|server) echo "$1" ;; *) echo test ;; esac; }

short() { local n="${1#ln-}"; case "$n" in ubuntu|debian|fedora|rocky|client|server) echo "$n" ;; *) die "unknown VM '$1' (ubuntu debian fedora rocky client server)" ;; esac; }
vm_dir() { echo "$state/vms/ln-$1"; }

pubkey() {
    local f
    for f in "${LN_SSH_PUBKEY:-}" ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
        [ -n "$f" ] && [ -r "$f" ] && { cat "$f"; return; }
    done
    die "no SSH public key found; set LN_SSH_PUBKEY"
}

firmware() {
    [ "$arch" = aarch64 ] || return 0
    local f
    for f in /opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd \
             /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw; do
        [ -r "$f" ] && { echo "$f"; return; }
    done
    die "aarch64 UEFI firmware not found (Homebrew qemu ships it; on Debian/Ubuntu install qemu-efi-aarch64)"
}

# ---------- cloud-init seed ----------

make_iso() { # <dir with user-data, meta-data[, network-config]> <out.iso>
    if command -v cloud-localds >/dev/null; then
        cloud-localds ${3:+--network-config "$3"} "$2" "$1/user-data" "$1/meta-data"
    elif command -v genisoimage >/dev/null; then genisoimage -quiet -output "$2" -volid cidata -joliet -rock "$1"/*
    elif command -v mkisofs >/dev/null; then mkisofs -quiet -output "$2" -volid cidata -joliet -rock "$1"/*
    elif command -v xorriso >/dev/null; then xorriso -as mkisofs -quiet -output "$2" -volid cidata -joliet -rock "$1"/*
    elif command -v hdiutil >/dev/null; then
        rm -f "$2" "$2.cdr"
        hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$2.cdr" "$1" && mv "$2.cdr" "$2"
    else die "need an ISO tool: cloud-localds, genisoimage, mkisofs, xorriso or hdiutil"; fi
}

make_seed() { # <short name> <vm dir>
    local n="$1" d="$2" s="$2/seed"
    mkdir -p "$s"
    cat > "$s/meta-data" <<EOS
instance-id: ln-$n-$(date +%s)
local-hostname: ln-$n
EOS
    cat > "$s/user-data" <<EOS
#cloud-config
hostname: ln-$n
manage_etc_hosts: true
package_update: false
package_upgrade: false
users:
  - name: $user
    groups: [sudo, wheel]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(pubkey)
write_files:
  - path: /usr/local/sbin/ln-provision
    permissions: "0755"
    encoding: b64
    content: $(base64 < "$provision" | tr -d '\n')
  - path: /etc/latencyninja-lab.env
    permissions: "0644"
    content: |
      ROLE=$(role_of "$n")
      FAMILY=$(family_of "$n")
      REPO_URL=$repo_url
      REPO_REF=$repo_ref
      LAB_IP=$(lab_ip_of "$n")
      ROUTE_NET=
      ROUTE_VIA=
runcmd:
  - [bash, -c, "/usr/local/sbin/ln-provision > /var/log/ln-provision.log 2>&1; echo \$? > /var/lib/ln-provision.rc"]
EOS
    local net=""
    if [ -n "$(lab_ip_of "$n")" ]; then
        net="$s/network-config"
        cat > "$net" <<EOS
version: 2
ethernets:
  mgmt:
    match: {name: "e*", macaddress: "$(mgmt_mac "$n")"}
    dhcp4: true
  lab:
    match: {macaddress: "$(lab_mac_of "$n")"}
    addresses: [$(lab_ip_of "$n")/24]
EOS
    fi
    make_iso "$s" "$d/seed.iso" ${net:+"$net"}
}

mgmt_mac() { printf '52:54:00:99:00:%02x' "$(( $(ssh_port_of "$1") % 256 ))"; }

# ---------- VM lifecycle ----------

fetch_image() { # <distro> -> path of the cached base image
    local url file
    url="$(image_url "$1")"; file="$state/images/$1-$arch.qcow2"
    if [ ! -f "$file" ]; then
        mkdir -p "$state/images"
        echo "Downloading $url" >&2
        curl -fL --progress-bar -o "$file.part" "$url" && mv "$file.part" "$file"
    fi
    echo "$file"
}

is_running() { local p; p="$(vm_dir "$1")/pid"; [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null; }

start_vm() { # <short name>
    local n="$1" d base
    d="$(vm_dir "$n")"
    command -v "$qemu" >/dev/null || die "$qemu not found (brew install qemu / apt install qemu-system)"
    command -v qemu-img >/dev/null || die "qemu-img not found"
    is_running "$n" && { echo "ln-$n is already running"; return; }
    mkdir -p "$d"
    if [ ! -f "$d/disk.qcow2" ]; then
        base="$(fetch_image "$(base_of "$n")")"
        qemu-img create -q -f qcow2 -b "$base" -F qcow2 "$d/disk.qcow2" "$disk"
        make_seed "$n" "$d"
    fi

    local args=(-name "ln-$n" -m "$memory" -smp "$cpus" -display none -daemonize -pidfile "$d/pid"
        -serial "file:$d/console.log"
        -drive "file=$d/disk.qcow2,if=virtio,format=qcow2"
        -drive "file=$d/seed.iso,if=virtio,format=raw,media=cdrom,readonly=on"
        -netdev "user,id=mgmt,hostfwd=tcp:127.0.0.1:$(ssh_port_of "$n")-:22"
        -device "virtio-net-pci,netdev=mgmt,mac=$(mgmt_mac "$n")")

    if [ "$arch" = x86_64 ]; then
        args+=(-machine "q35,accel=$accel")
        [ "$accel" = tcg ] && args+=(-cpu qemu64) || args+=(-cpu host)
    else
        args+=(-machine "virt,accel=$accel" -bios "$(firmware)")
        [ "$accel" = tcg ] && args+=(-cpu max) || args+=(-cpu host)
    fi

    # Private client<->server link: the server listens, the client connects (start the server first)
    case "$n" in
        server) args+=(-netdev "socket,id=lab,listen=127.0.0.1:$lab_link_port" -device "virtio-net-pci,netdev=lab,mac=$(lab_mac_of server)") ;;
        client) args+=(-netdev "socket,id=lab,connect=127.0.0.1:$lab_link_port" -device "virtio-net-pci,netdev=lab,mac=$(lab_mac_of client)") ;;
    esac

    "$qemu" "${args[@]}"
    echo "Started ln-$n (ssh port $(ssh_port_of "$n"))"
}

stop_vm() {
    local d; d="$(vm_dir "$1")"
    if is_running "$1"; then kill "$(cat "$d/pid")"; echo "Stopped ln-$1"; fi
    rm -f "$d/pid"
}

ssh_vm() { # <short> [cmd...]
    local n="$1"; shift
    # SSH_EXTRA (e.g. -t) has to come before the host, so it is not part of "$@"
    # shellcheck disable=SC2086
    ssh ${SSH_EXTRA:-} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        -p "$(ssh_port_of "$n")" "$user@127.0.0.1" "$@"
}

existing_vms() { ls "$state/vms" 2>/dev/null | sed 's/^ln-//' || true; }

selection() { # args -> short names, in a start-safe order (server before client)
    local a out=()
    for a in "$@"; do
        if [ "$a" = lab ]; then out+=(server client); else out+=("$(short "$a")"); fi
    done
    printf '%s\n' "${out[@]}"
}

action="${1:-}"; shift || true
case "$action" in
    up)
        [ $# -gt 0 ] || set -- ubuntu
        for n in $(selection "$@"); do start_vm "$n"; done
        echo "First boot installs dependencies and takes a few minutes: qemu-lab.sh wait"
        ;;
    wait)
        # shellcheck disable=SC2046
        [ $# -gt 0 ] || set -- $(existing_vms)
        for n in $(selection "$@"); do
            printf 'Waiting for ln-%s ' "$n"
            for _ in $(seq 1 120); do
                if ssh_vm "$n" test -f /var/lib/ln-provision.done 2>/dev/null; then echo "ready"; continue 2; fi
                printf '.'; sleep 10
            done
            die "ln-$n did not finish provisioning; see: qemu-lab.sh ssh $n sudo cat /var/log/ln-provision.log"
        done
        ;;
    status)
        printf '%-12s %-8s %s\n' VM STATE SSH
        for d in "$state"/vms/ln-*; do
            [ -d "$d" ] || continue
            n="${d##*/ln-}"
            printf '%-12s %-8s ssh -p %s %s@127.0.0.1\n' "ln-$n" "$(is_running "$n" && echo running || echo stopped)" "$(ssh_port_of "$n")" "$user"
        done
        ;;
    ssh)
        [ $# -ge 1 ] || die "usage: qemu-lab.sh ssh <vm> [cmd...]"
        n="$(short "$1")"; shift
        ssh_vm "$n" "$@"
        ;;
    test)
        [ $# -ge 1 ] || die "usage: qemu-lab.sh test <vm> [filter]"
        n="$(short "$1")"; shift
        SSH_EXTRA=-t ssh_vm "$n" ln-test "$@"
        ;;
    down)
        # shellcheck disable=SC2046
        [ $# -gt 0 ] || set -- $(existing_vms)
        for n in $(selection "$@"); do stop_vm "$n"; done
        ;;
    destroy)
        # shellcheck disable=SC2046
        [ $# -gt 0 ] || set -- $(existing_vms)
        for n in $(selection "$@"); do stop_vm "$n"; rm -rf "$(vm_dir "$n")"; echo "Deleted ln-$n"; done
        ;;
    *) sed -n '3,22p' "$0"; exit 1 ;;
esac
