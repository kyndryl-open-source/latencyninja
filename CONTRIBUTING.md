# Contributing to Latency Ninja

## Development workflow

Each release is developed on a branch named after its version, then merged into `main` through a pull request.

1. Start the next version from an up-to-date `main`:

       tools/bump_version.sh --branch          # 1.22 -> 1.23, creates branch 1.23
       tools/bump_version.sh major --branch    # 1.22 -> 2.0

   This updates `version.txt` (the single source of truth: `--version` and the updater read it) and adds a `CHANGELOG <version>` section to `CHANGELOG.md`.

2. Make your changes and list them under the new version in `CHANGELOG.md`.

3. Run the test suite in a VM (see [tests/README.md](tests/README.md)):

       tests/vm.sh up ubuntu && tests/vm.sh test ubuntu
       tests/vm.sh up fedora && tests/vm.sh test fedora    # for distro-specific changes
       tests/vm.sh reboot-test ubuntu                      # for persistence changes

4. Check the version and changelog, then open a pull request to `main`:

       tools/check_version.sh

## Continuous integration

Every pull request runs:

- **Lint**: bash syntax and ShellCheck (errors).
- **Version bump and CHANGELOG**: `version.txt` must be greater than `main`'s and documented in `CHANGELOG.md`.
- **Functional tests**: the full `tests/run_tests.sh` suite on an Ubuntu runner.

## Releases

Releases are automatic. When a pull request that changes `version.txt` is merged into `main`, the Release workflow creates the `vX.Y` tag and a GitHub release whose notes are that version's `CHANGELOG.md` entries. Users running `./latencyninja --update` are then offered the new version.
