# Latency Ninja test environment

Latency Ninja needs Linux, root, `tc/netem` and the `ifb` module, so tests run inside
disposable [Lima](https://lima-vm.io) VMs. The repo is mounted read-only into the VM at the
same path, so edits on the host are tested immediately.

## Quick start (macOS)

    brew install lima
    tests/vm.sh up ubuntu        # or: fedora
    tests/vm.sh test ubuntu      # run the full suite, in parallel (about 90 seconds)
    tests/vm.sh test ubuntu @quick  # only the tests that measure no traffic and wait for no timers (about 30 seconds)
    tests/vm.sh test ubuntu json # run only tests whose name contains "json", in order
    tests/vm.sh test-all         # ubuntu and fedora at the same time
    tests/vm.sh test-serial ubuntu  # the whole suite, one test after the other (about 5 minutes)
    tests/vm.sh reboot-test ubuntu  # check --persist rules survive a VM reboot
    tests/vm.sh shell ubuntu     # interactive shell in the repo dir
    tests/vm.sh down ubuntu      # stop (destroy to delete)

## How it works

`netns_setup.sh` builds an isolated topology so the VM's real `eth0` is never touched:

    ln0   10.10.0.1  <--veth-->     [netns lnpeer] 10.10.0.2/.3/.4, 10.20.0.1
    bond0 10.40.0.1  <--2x veth-->  bridge 10.40.0.2 (active-backup bond)
    wg0   10.30.0.1  <--over ln0--> wgp0 10.30.0.2
                                    TCP listeners on 80, 443, 8080, 9090

`run_tests.sh` applies rules to `ln0` and verifies them by measuring real traffic
(ping RTT/loss/duplicates, TCP connect times per port), plus `tc` state, `--query`,
`--rollback`, JSON import, backup/logging files, snapshots, persistence (interface re-creation),
bonded and WireGuard interfaces, bandwidth limits (measured TCP throughput), profiles, timed
rollbacks, validation errors, input normalization, `--dry-run`, the SSH lockout guard (simulated with `SSH_CONNECTION`), `--check`/`--clean` and the updater.

## Running in parallel

`tests/vm.sh test <distro>` runs `tests/run_parallel.sh` in the VM. Most of the time of the suite is spent measuring
real traffic, so the tests are spread over isolated shards (one per CPU, at most 6) that run at the same time. A shard
(`shard.sh`) runs in its own network, mount and PID namespaces and builds its own copy of the test topology, so
every shard can use `ln0`, `lnpeer` and the same addresses; the paths the suite writes to (`/run/latencyninja`,
`/tmp/lntest`, persisted rules, WireGuard keys, tmux and screen sockets) are private to it. In a shard, timers are
started by stand-ins for `systemd-run` and `systemctl` (`tests/shim`), because the real ones would run them in the
host's namespaces.

Tests that need the real systemd (persistence units, a real timer), containers or other state shared with the
host run one after the other in the host's namespaces at the same time as the shards (`test_class` in
`run_tests.sh` decides: it looks at what a test uses, and `real_systemd_tests` and `shard_safe_tests` override it). That
group is now what the run waits for. `tests/weights.txt` holds the duration of each test, to balance the shards.

When you add a test, nothing needs to be done: it runs in a shard unless it uses persistence, containers, `--check`,
`--clean` or a process target. If a test fails only in the parallel run, run it alone with `tests/vm.sh test <distro> <name>`;
the stand-in `systemctl` says "needs the real systemd" when a test uses more than timers, and the fix is to add the
test to `real_systemd_tests`.
