# Latency Ninja test environment

Latency Ninja needs Linux, root, `tc/netem` and the `ifb` module, so tests run inside
disposable [Lima](https://lima-vm.io) VMs. The repo is mounted read-only into the VM at the
same path, so edits on the host are tested immediately.

## Quick start (macOS)

    brew install lima
    tests/vm.sh up ubuntu        # or: fedora
    tests/vm.sh test ubuntu      # run the full suite
    tests/vm.sh test ubuntu json # run only tests whose name contains "json"
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
rollbacks, validation errors, input normalization, the SSH lockout guard (simulated with `SSH_CONNECTION`), `--check`/`--clean` and the updater.
