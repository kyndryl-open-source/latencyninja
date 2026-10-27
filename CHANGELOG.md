CHANGELOG 1.28.4
- tools/bump_version.sh no longer adds a CHANGELOG stub, it only updates version.txt; the CHANGELOG entry is written by hand and CI still requires it (CONTRIBUTING.md updated)

CHANGELOG 1.28.2
- Added examples/: guidance for human testers to try Latency Ninja on real hosts. examples/terraform builds VMs on Proxmox, AWS, Azure and Google Cloud (distro VMs that run the functional suite, Ubuntu, Debian, Fedora and Rocky where the platform has them, and a client/server lab, with an optional router on Proxmox); examples/qemu does the same on a workstation with plain QEMU (no libvirt, no root, KVM or HVF); examples/docker is a client/server container lab with a walk-through of --container. Not part of the tool: CI does not lint or run any of it

CHANGELOG 1.28.1
- Fixed an endless loop (a silent 100% CPU spin) when --json, --backup or --logging was the last argument without a value; they now report that the option requires an argument
- A failed or interrupted (Ctrl-C) apply now puts the interface back as it was: before, an error from tc left an ifb device, an ingress qdisc and redirects behind, and --check reported nothing wrong. The pending timed rollback of the previous rules is kept
- An unwritable --logging path is reported before any rules are applied. Before, the rules stayed applied and, with --duration, no rollback timer was scheduled, so the safety net was missing. --dry-run checks it too
- --reorder without --latency is an error, as tc refuses it (it was a warning, followed by a half-applied failure)
- latency and jitter above what tc accepts (274877 ms per direction) and absurd or unusable rates are rejected; tc silently wrapped some of them into other values. The latency and jitter split for --direction both keeps its precision
- --rollback only removes the qdiscs Latency Ninja set up, and applying rules warns when it replaces a qdisc you configured (htb, cake, clsact...); before, --rollback deleted the root and ingress qdiscs of an interface even when Latency Ninja had never touched it
- ping, iputils and inetutils-ping are no longer required: nothing used ping, and on Debian and Ubuntu the check offered to install inetutils-ping, which replaces iputils-ping (and removes ubuntu-minimal)
- Removed unused code, including a debug helper
- Tests: the failed apply test uses a tc that fails (it used a value that is now rejected by validation); new tests for every fix above

CHANGELOG 1.28
- Added --dry-run: validates the options like a normal run, including the SSH lockout guard, and prints the tc/ip commands that would be run without changing anything (no rules, backup, log, persistence or timer); it can't be combined with --rollback, --check, --clean, --save, --restore or --apply-persisted
- The egress filter for rules with swapped source and destination no longer prints the port and "Running:" debug lines
- Roadmap: --dry-run removed (done); the rest of the safety and automation items are now 1.29, and the planned versions after it moved by one

CHANGELOG 1.27
- Added --check and --clean: --check finds leftovers (ifb devices no interface uses, rules redirecting to a missing ifb device, saved rules and timed rollbacks of interfaces, containers and namespaces that are gone, persisted rules that can't be applied, persistence units left installed, old backups) and invalid profiles without changing anything and exits 1 if it finds a problem; --clean lists what it can remove, asks for confirmation (--yes skips it) and removes it. Active rules, valid persisted rules and pending timed rollbacks are never touched; works on one container or namespace with --container, --netns and --pid
- Added an SSH lockout guard: rules that would affect an SSH session reaching the machine through the target interface are refused unless --duration is used (rules roll back by themselves, with a warning) or --allow-ssh ("allow_ssh" in JSON files) is given
- Stricter input validation, shared by the command line, JSON files and profiles: numbers are no longer stripped of other characters (abc50 and 1.2.3 were accepted before), percentages above 100 are rejected, "ms" and "%" suffixes and surrounding spaces are accepted, and numbers are normalized (005 becomes 5)
- Stricter IP and port validation: octets above 255 and prefix lengths above 32 are rejected, leading zeros are removed so 010.0.0.1 is not read as octal, empty ports are errors instead of being dropped, duplicate addresses are removed, and a port is checked to be a number before it is used (a non-numeric port was evaluated by bash as an arithmetic expression, which can run commands as root; this mattered for JSON files, snapshots and persisted rules from untrusted sources)
- direction, rate and duration are case insensitive; warnings for jitter larger than latency and for --reorder without --latency
- Roadmap: added a Starlink profile (1.29), inter-AZ and cloud inter-region profiles (1.30), Starlink handover scenarios (1.31) and a Kubernetes sidecar image (2.0)

CHANGELOG 1.26.1
- --show-interfaces now requires root like every other command, so there is no exception to remember; it always shows persistence and timed rollbacks

CHANGELOG 1.26
- JSON files support every option that applies rules: added container, netns, pid, persist, backup and logging; src_ip/dst_ip can be arrays and numbers don't need quotes; unknown keys, wrong value types and invalid JSON are rejected
- --persist works with --container and --netns: a watcher service (latencyninja-namespaces) re-applies the rules when the container restarts or the namespace or interface is re-created; containers are tracked by name; --pid can't be persisted
- Host snapshots (--save without --interface) include the rules of all containers and namespaces, and --restore re-enters each one
- Runtime state and timers are keyed by the network namespace itself, so a namespace reached in different ways (e.g. --container and --pid) shares its state, and a target in the host namespace is treated as the host
- Profiles with unknown keys are rejected
- Commands suggested by Latency Ninja (rollback, query, restore) and all examples in the README, USAGE.md and templates consistently use sudo
- Roadmap: planned versions moved by one (safety and automation is now 1.27)

CHANGELOG 1.25
- Added --container (Docker and Podman), --netns and --pid to apply, query, list (--show-interfaces), snapshot and roll back rules inside a container or network namespace instead of the whole host
- State, snapshots and timed rollbacks are kept per namespace; snapshots record their namespace and must be restored in the same one; --persist is refused inside namespaces
- Suggested commands (rollback, restore, query) include the namespace option when one is used
- Interfaces are listed with ip instead of /sys/class/net, which shows the host's devices inside a namespace
- Added USAGE.md with detailed examples of every feature, and more examples in the README

CHANGELOG 1.24
- Added --show-interfaces to list interfaces with their type (ethernet, bond, WireGuard, ...), IPv4 address and Latency Ninja status (rules, persistence, timed rollback); works without root. Based on a contribution by @scopey (#46)
- README lists the required packages per distribution (contributed by @scopey in #46) and notes that git is only needed for --update
- Contributions now target the open version branch; CONTRIBUTING.md and the PR template explain the workflow
- Fixed intermittent bond test failures: the test topology now waits for udev before enslaving veths, so slave MAC addresses match the bond

CHANGELOG 1.23
- Starting with v1.23, I've started using Claude (Anthropic's AI assistant) to help develop Latency Ninja
- Added --duration (-t) to roll back automatically after a time (e.g. 30s, 10m, 2h), restoring the rules that were in place before; --query shows pending rollbacks
- Added --rate (-b) to limit bandwidth per direction (e.g. 512kbit, 2mbit, 1gbit)
- Added --profile (-p) with built-in network profiles (3g, 4g, 5g, satellite, leo-satellite, transatlantic, transpacific, lossy-wifi), custom profiles in /etc/latencyninja/profiles and --profiles to list them
- JSON files accept "rate", "profile" and "duration"
- Fixed invalid numeric values (e.g. --latency 0) not stopping execution before tc was called
- Fixed the "option requires an argument" error message showing three dashes
- tools/bump_version.sh no longer makes the new version branch track origin/main

CHANGELOG 1.22
- Fixed check_system_requirements() to only check for 'git' when --update is used
- Added an autobackup capability to keep track of current tc rules
- Added a logging capability to keep track of injections
- Added --persist to re-apply rules at boot and when an interface is re-created (systemd + udev)
- Added --save and --restore for restorable snapshots; automatic backups are now restorable snapshots
- Each interface now uses its own ifb devices (lni-<iface>/lne-<iface>), so several interfaces can be shaped at once (previously shaping a second interface broke the first)
- Verified support for bonded and WireGuard interfaces
- Fixed --version reporting 1.21 (now read from version.txt)
- Fixed the --rollback without --interface error message
- Latency Ninja can now be run from any directory
- Uses the first IPv4 address when an interface has several
- Fixed --query listing bonding_masters as a device
- Added a functional test suite under tests/ (Lima VMs, Ubuntu and Fedora)
- Added GitHub Actions CI (lint, version/CHANGELOG check, functional tests) and automatic tagged releases on merge to main
- Added tools/bump_version.sh to start a new version and CONTRIBUTING.md describing the workflow 

CHANGELOG 1.21
- Updater will run as original user to keep file permissoins consistent
- Cleaned up some commenting and documentation
- Changed location of repo to https://github.com/kyndryl-open-source/latencyninja

CHANGELOG 1.20
- Fixed updater

CHANGELOG 1.19
- Enhanced import arguments from JSON
- Enhanced find_command_paths()
- Removed 'bc' as a required package
- Added more debug information when using --debug

CHANGELOG 1.18
- Added a feature to import arguments from JSON using --json filejson

CHANGELOG 1.17
- Git hooks cleanup
- Enhanced updater
- Enhanced README file to show the new capabilities

CHANGELOG 1.16
- Testing updater

CHANGELOG 1.15
- Testing updater

CHANGELOG 1.14
- Testing updater

CHANGELOG 1.13
- Fixing the updater to get the latest version directly from Github. Still BETA 

CHANGELOG 1.12
- Fixed root/sudo checks
- Fixed the updater to get the latest version directly from github. Still BETA

CHANGELOG 1.11
- Fixed the updater, if using git, it will go a git pull. Still BETA
- Fixed an issue with --src_ip and ports for ip swapping

CHANGELOG 1.10
- Fixed the updater. Still BETA

CHANGELOG 1.9
- Added an updater function to check if there's a new version and allow the user to update. BETA
- Re-did the get_arguments to better expect user arguments
- Simplified a bit the die() function
- Fixed a function to ensure that the interface exists

CHANGELOG 1.8
- Created AI Generated Logo for Latency Ninja
- Fixed load_ifb_module outputting that module is already available
- Added inetutils-ping as part of depdencies for Debian based systems and iptules for red hat based systems
- Added .git/hooks/pre-commit to change the version variable every time a commit is done.
- Fixed a set default src_ip and dst_ip based on rules
- Added a :0 to local_ip so now all IPs have at least a port, 0 means: any
- rollback_everything is called every time before setting new rules. This needs to become smart to only overwrite what is changed.

CHANGELOG 1.7
- Fixed GPL License to v2.0 all over

CHANGELOG 1.6
- Refactored the entire code base, optimized and compacted it
- Removed test functions
- Divided source code into multiple files for readiability
- General enhancements
- Created a --query to display current tc rules
- Introduced --about and optimized--help

CHANGELOG 1.5
- Added a latencyninjaquery.sh capability to show current rules (work in progress)
- Added capabilities to add rules based on multiple destination ports
- Added a perspective function for source_ips that flips src_ip and dst_ip (need to check if his works as Router mode or Bridge mode later)
- Temporarly removed the pre/post rule tests/pings
- Started capability for multiple src_ips (INCOMPLETE)

CHANGELOG 1.4
- Clearified some documentation in usage() and in the README.
- Changed packet-loss to packet_loss
- Renamed validate_numeric_format() to validate_numeric
- Renamed validate_ip_format() to validate_ip()
- Created validate_test_method() to check if the test is icmp or http
- Refactored the ping_destination() and extracted is_single_host() to it can be tested for ping/icmp and curl/http
- Replaced all pinging() and ping* related functions with test_destination() that allow for both icmp/ping and curl/http
- Added curl as a dependency for http testing
- Changed $selected_interface to $interface
- Reformated the ping output and made a new way of outputing icmp/ping and curl/http tests
- Replaced -p with -c (test_counts) and -t (test_methods)
- Enhanced create_virtual_interface()
- Enhanced rollback_everything()
- Fixed all instances of delete_qdisc_if_exists() which had wrong handles causing disconnections

CHANGELOG 1.3
- Fixed display_after_message() to show $selected_interface
- Fixed random bash best practices based on ShellCheck
- Did some README.md fixes
- Simplified the die() function
- Removed useless calls for usage() all over the script
- Added absolute paths for commands such as ip, tc, ping, modprobe etc.
- Added kmod as a dependency
- Added version info in die()
- Changed the location of cleanup for numeric values to the parse_arguments()
- Fixed the validation for validate_numeric_format()
- Fixed the validation for validate_ip_format()regex for the IPv4 validation / Removed IPv6 validation for now
- Added rollback_everything if rollback_required=1 during die()

CHANGELOG 1.2
- Added variable versioning
- Added jitter for both
- Fixed splitting latency and jitter to support factorials so / 2 = 0.*
- Changed default direction to 'both' instead of 'egress'
- Enabled multiple --dst_ip using a -d 192.168.1.100,192.168.1.103,she192.168.101.0/24 format
- Enhanced usage()
- Other general enhancements

CHANGELOG 1.1
- Removed validate_direction() as it was not used
- Added more comments for readability and understanding
- Allows -h|--help to run without checking root and dependencies
- Changed interpreter to #!/usr/bin/env bash
- Enhanced create_virtual_interface()
- Enhanced die() for multiple --debug modes
- Added variables initialization

CHANGELOG 1.0
- Changed validate_numeric_format() to support only positive and decimal numbers
- Decoupled ingress and egress and re-factored code in configure_traffic_controls()
- Refactored and modularized pinging()
- Changed main() to apply above changes
- Added support for networks
- Allowed to run on egress, ingress or both 
- Added debug mode with flags 1 and 2
- Forced jitter to run only when latency is provided
- Skipped ping if network (eg. /24, or /16 etc. are provided)
- Added validation for IPs and Networks
