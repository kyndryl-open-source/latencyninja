#!/usr/bin/env bash
# First-boot provisioning for a Latency Ninja test VM. Driven by /etc/latencyninja-lab.env.
set -euxo pipefail
. /etc/latencyninja-lab.env

need_reboot=0
have_modules() { modprobe ifb && modprobe sch_netem; }
. /etc/os-release

case "$FAMILY" in
    debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq kmod iproute2 inetutils-ping curl jq git python3 wireguard-tools \
            podman iperf3 tcpdump ethtool bridge-utils
        # Cloud kernels ship without sch_netem/ifb; Ubuntu keeps them in linux-modules-extra
        have_modules || { apt-get install -y -qq "linux-modules-extra-$(uname -r)" || true; }
        # Debian's cloud kernel has no such package: switch to the full kernel (takes effect after the reboot below)
        if ! have_modules && [ "$ID" = debian ]; then
            apt-get install -y -qq linux-image-amd64
            need_reboot=1
        fi
        ;;
    rhel)
        dnf -y -q install kmod iproute iproute-tc curl jq git python3 podman iperf3 tcpdump ethtool
        # wireguard-tools is in EPEL on Rocky/RHEL, in the base repos on Fedora
        if [ "$ID" != fedora ]; then dnf -y -q install epel-release; fi
        dnf -y -q install wireguard-tools
        # The modules package must match the running kernel; otherwise take the newest and reboot into it
        dnf -y -q install "kernel-modules-extra-$(uname -r)" || { dnf -y -q install kernel kernel-modules-extra; need_reboot=1; }
        ;;
esac
have_modules || [ "$need_reboot" = 1 ] || { echo "sch_netem/ifb unavailable on this kernel"; exit 1; }

# Load the modules the suite needs on every boot (bonding and wireguard are used by the bond/wg tests)
printf '%s\n' ifb sch_netem bonding wireguard > /etc/modules-load.d/latencyninja.conf
for m in ifb sch_netem bonding wireguard; do modprobe "$m" || true; done  # may fail until the reboot

# Repo checkout in a fixed place, plus helpers
if [ ! -d /opt/latencyninja/.git ]; then
    git clone --branch "$REPO_REF" "$REPO_URL" /opt/latencyninja
fi

cat > /usr/local/bin/ln-test <<'EOS'
#!/usr/bin/env bash
# Update the checkout and run the functional suite: ln-test [name-filter]   (ln-test --ref <branch|tag> first to switch)
set -e
cd /opt/latencyninja
if [ "${1:-}" = "--ref" ]; then git fetch -q --all --tags && git checkout -q "$2" && shift 2; fi
git pull -q --ff-only 2>/dev/null || true
exec sudo bash tests/run_tests.sh "$@"
EOS
chmod 755 /usr/local/bin/ln-test
ln -sf /opt/latencyninja/latencyninja /usr/local/bin/latencyninja
chown -R root:root /opt/latencyninja

# Lab roles
case "$ROLE" in
    server)
        # Listeners that the --dst-port tests and iperf3 can hit
        for p in 80 443 8080 9090; do
            cat > "/etc/systemd/system/ln-listener-$p.service" <<EOS
[Unit]
Description=Latency Ninja test listener on $p
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server $p --directory /var/tmp
Restart=always
[Install]
WantedBy=multi-user.target
EOS
        done
        cat > /etc/systemd/system/ln-iperf3.service <<'EOS'
[Unit]
Description=iperf3 server
After=network.target
[Service]
ExecStart=/usr/bin/iperf3 -s
Restart=always
[Install]
WantedBy=multi-user.target
EOS
        systemctl daemon-reload
        systemctl enable --now ln-iperf3 ln-listener-80 ln-listener-443 ln-listener-8080 ln-listener-9090
        ;;
    router)
        echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-ln-router.conf
        sysctl --system >/dev/null
        ;;
    client|test) : ;;
esac

# Client/server: route to the far lab segment through the router
if [ -n "${ROUTE_NET:-}" ]; then
    cat > /etc/systemd/system/ln-lab-route.service <<EOS
[Unit]
Description=Route to the far lab segment via the router
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace $ROUTE_NET via $ROUTE_VIA
[Install]
WantedBy=multi-user.target
EOS
    systemctl daemon-reload
    systemctl enable --now ln-lab-route
fi

# Fedora/Rocky: SELinux and firewalld would block the listeners and forwarding in the lab
if command -v systemctl >/dev/null && systemctl is-active --quiet firewalld; then systemctl disable --now firewalld; fi

touch /var/lib/ln-provision.done
[ "$need_reboot" = 1 ] && { echo "rebooting into the full kernel"; systemctl reboot --no-block; }
exit 0
