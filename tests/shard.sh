#!/usr/bin/env bash
#
# Run part of the test suite in isolation, so several shards can run at the same time (see run_parallel.sh).
# Meant to be started with: unshare --mount --net --pid --fork --mount-proc bash tests/shard.sh
#
# Inside its own network namespace a shard builds its own copy of the test topology (ln0, bond0, wg0 and the
# lnpeer namespace), and the paths the suite writes to are private (tmpfs mounts, a key directory of its own), so
# shards can't see each other.
# The tests to run come from LN_TESTS.

set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"

mount --make-rprivate /
for dir in /run/netns /run/latencyninja /run/ln-shard /tmp/lntest; do
    mkdir -p "$dir"
    mount -t tmpfs tmpfs "$dir"
done
ip link set lo up

# Timers: stand-ins for systemd-run and systemctl start them inside the shard, since the real ones would run
# them in the host's namespaces. /run/systemd/system only has to exist, as the tool checks for it.
mkdir -p /run/ln-shard/units /run/ln-shard/screen
chmod 700 /run/ln-shard/screen
mount -t tmpfs tmpfs /run/systemd 2>/dev/null || true
mkdir -p /run/systemd/system
export PATH="$repo_dir/tests/shim:$PATH"
# tmux and screen keep their sockets in private directories
export TMUX_TMPDIR=/run/ln-shard SCREENDIR=/run/ln-shard/screen
export LN_PID_FILE=/run/ln-shard/listener.pid
# Persisted rules live in /etc/latencyninja/persist, which the host shares: keep the shard's own
export LATENCYNINJA_PERSIST_DIR=/run/ln-shard/persist
# The WireGuard keys must be under /etc/wireguard (AppArmor). A directory of its own, not a mount: removing a
# directory that is a mount point in another namespace would unmount it there.
export LN_KEY_DIR="/etc/wireguard/latencyninja-test-shard-$RANDOM$RANDOM"
trap 'rm -rf "$LN_KEY_DIR"' EXIT

bash "$repo_dir/tests/run_tests.sh" "${1:-}"
