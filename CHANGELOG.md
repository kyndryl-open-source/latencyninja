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
