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
- Removed validate_direction() as it was not used.
- Added more comments for readability and understanding.
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
