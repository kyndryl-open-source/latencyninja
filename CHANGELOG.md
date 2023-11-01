CHANGELOG 1.20
- Fixed updater

CHANGELOG 1.19
- Enhanced import arguments from JSON
- Enhanced find_command_paths()
- Removed 'bc' as a required package
- Added more debug information when using --debug

CHANGELOG 1.18
- Added a feature to import arguments from JSON using --json file.json

CHANGELOG 1.17
- Git hooks cleanup
- Enhanced updater
- Enhanced README file to show the new capabilities

CHANGELOG 1.16
- Testing updater.

CHANGELOG 1.15
- Testing updater.

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
