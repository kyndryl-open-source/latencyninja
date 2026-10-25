#!/bin/bash
# This file is part of Latency Ninja.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License v2.0 as published by
# the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Latency Ninja.  If not, see <https://www.gnu.org/licenses/>.

# Function to validate arguments given
get_arguments() {
    if [ $# -eq 0 ]; then
        usage
    fi

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -a|--about) about; exit 0 ;;
            -v|--version) version; exit 0;;
            -q|--query) query; exit 0 ;; 
            --show-interfaces) show_available_interfaces; exit 0 ;;
            --check) check_mode=1; shift ;;
            --clean) clean_mode=1; shift ;;
            --yes) assume_yes=1; shift ;;
            --allow-ssh) allow_ssh=1; shift ;;
            -r|--rollback) rollback_required=1; shift;;
            -i|--interface) process_arg eth_interface interface_provided "$@"; shift 2 ;;
            -s|--src_ip) process_arg validate_src_ip "" "$@"; shift 2 ;;
            -d|--dst_ip) process_arg validate_dst_ip "" "$@"; shift 2 ;;
            -w|--direction) process_arg direction "" "$@"; shift 2 ;;
            -l|--latency) process_arg latency latency_provided "$@"; shift 2 ;;
            -j|--jitter) process_arg jitter jitter_provided "$@"; shift 2 ;;
            -x|--packet_loss) process_arg packet_loss "" "$@"; shift 2 ;;
            -y|--duplicate) process_arg duplicate "" "$@"; shift 2 ;;
            -z|--corrupt) process_arg corrupt "" "$@"; shift 2 ;;
            -k|--reorder) process_arg reorder "" "$@"; shift 2 ;;
            -b|--rate) process_arg rate "" "$@"; shift 2 ;;
            -p|--profile) process_arg profile "" "$@"; shift 2 ;;
            --profiles) list_profiles; exit 0 ;;
            -t|--duration) process_arg duration "" "$@"; shift 2 ;;
            --timed-rollback) process_arg timed_rollback_file "" "$@"; shift 2 ;;
            --json) json_file="$2"; shift 2 ;;
            --backup) backup_dir="$2"; shift 2 ;;
            --logging) log_file="$2"; shift 2 ;;
            --save) process_arg save_file "" "$@"; shift 2 ;;
            --restore) process_arg restore_file "" "$@"; shift 2 ;;
            --persist) persist=1; shift ;;
            --apply-persisted) process_arg apply_persisted "" "$@"; shift 2 ;;
            --keep-persist) keep_persist=1; shift ;;
            --watch-namespaces) watch_namespaces; exit 0 ;;
            --update) update; exit 0 ;;
            --debug) debug=true; shift ;;
            *) echo "Invalid option: $1"; exit 1 ;;
        esac
    done
}

# Function to validate arguments given
process_arg() {
    local var_name="$1"
    local flag_name="$2"

    shift 2
    if [[ -z "$2" || "$2" == -* ]]; then
        die "The $1 option requires an argument."
    else
        if [[ -n "$flag_name" ]]; then
            declare -g "$flag_name=1"
        fi
        if [[ "$var_name" == validate_* ]]; then
            "$var_name" "$2"
        else
            declare -g "$var_name=$2"
        fi
    fi
}

# Function to parse arguments
parse_arguments() {
    # --check and --clean audit Latency Ninja's own state and don't apply rules
    if [ "$check_mode" -eq 1 ] || [ "$clean_mode" -eq 1 ]; then
        [ -n "$json_file$eth_interface$src_ip_arg$dst_ip_arg$latency$jitter$packet_loss$duplicate$corrupt$reorder$rate$profile$duration$save_file$restore_file$apply_persisted" ] || [ "$persist" -eq 1 ] || [ "$rollback_required" -eq 1 ] &&
            die "The --check and --clean options can't be combined with options that apply, roll back or restore rules."
        run_check_clean
        exit $?
    fi

    # Options from the JSON file override the same options given on the command line
    [ -n "$json_file" ] && load_json_file "$json_file"
    normalize_parameters

    # Fill in parameters that weren't given explicitly from the selected profile
    if [ -n "$profile" ]; then
        load_profile "$profile"
        normalize_parameters
    fi

    # Validate the interface if one was given to scope --save/--restore
    if [ -n "$eth_interface" ] && { [ -n "$save_file" ] || [ -n "$restore_file" ]; }; then
        $ip_path link show "$eth_interface" &>/dev/null || die "Invalid interface: $eth_interface. Please provide a valid network interface."
    fi

    # Modes that don't apply new rules
    [ -n "$apply_persisted" ] && { apply_persisted_rules "$apply_persisted"; exit $?; }
    [ -n "$save_file" ] && { save_snapshot "$save_file" "$eth_interface"; exit $?; }
    [ -n "$restore_file" ] && { restore_snapshot "$restore_file" "$eth_interface"; exit $?; }

    # Check that -r is used with -i
    if [ "$rollback_required" -eq 1 ] && [ "$interface_provided" -eq 0 ]; then
        die "The -r|--rollback option requires the -i|--interface option."
    fi

    # Validate the selected interface
    if [ -z "$eth_interface" ] || ! $ip_path link show "$eth_interface" &>/dev/null; then
        die "Invalid interface: $eth_interface. Please provide a valid network interface."
    fi
    set_ifb_interfaces "$eth_interface"

    [ -n "$timed_rollback_file" ] && { run_timed_rollback "$eth_interface" "$timed_rollback_file"; exit $?; }

    if [ "$rollback_required" -eq 1 ]; then
        rollback_everything
        cancel_scheduled_rollback "$eth_interface"
        clear_runtime_state "$eth_interface"
        [ "$keep_persist" -eq 0 ] && unpersist_rules "$eth_interface"
        echo -e "\nRolled back network perturbations changes for interface $eth_interface."
        exit 0
    fi

    [ "$persist" -eq 1 ] && check_persist_supported
    if [ -n "$duration" ]; then
        [ "$persist" -eq 1 ] && die "The --duration option cannot be combined with --persist."
        command -v systemd-run &>/dev/null && [ -d /run/systemd/system ] || die "The --duration option requires systemd."
    fi
    
    local_ip=$($ip_path -o -4 address show dev "$eth_interface" | awk 'NR==1 {print $4}' | cut -d'/' -f1)
    if [ -z "$local_ip" ] && { [ "${#src_ip[@]}" -eq 0 ] || [ "${#dst_ip[@]}" -eq 0 ]; }; then
        die "Interface $eth_interface has no IPv4 address. Assign one or provide both --src_ip and --dst_ip."
    fi
    local_ip="${local_ip}:0"

    # If src_ip is provided but dst_ip is not, set dst_ip to local_ip
    if [ "${#src_ip[@]}" -gt 0 ] && [ "${#dst_ip[@]}" -eq 0 ]; then
        dst_ip=("$local_ip")  # Assign as an array
    fi

    # If src_ip is not provided, set it to local_ip
    if [ "${#src_ip[@]}" -eq 0 ]; then
         src_ip=("$local_ip")  # Assign as an array
    fi

    # Validate mandatory parameters
    [ -z "$eth_interface" ] || [ "${#src_ip[@]}" -eq 0 ] || [ "${#dst_ip[@]}" -eq 0 ] || [ -z "$direction" ] &&
        die "Interface, destination or source IP/network are mandatory. Use --help for usage information."

    # Validate other mandatory parameters
    [ -z "$latency" ] && [ -z "$jitter" ] && [ -z "$duplicate" ]  && [ -z "$corrupt" ] && [ -z "$reorder" ] && [ -z "$packet_loss" ] && [ -z "$rate" ] &&
        die "At least one of the parameters (latency, jitter, duplicate, corrupt, reorder, packet_loss, rate) or a profile must be provided. Use --help for usage information."

    # Check that jitter comes with latency (from the command line, JSON or a profile)
    if [ -n "$jitter" ] && [ -z "$latency" ]; then
        die "Jitter can only be used with latency. Use --help for usage information."
    fi

    # Check that direction is only egress, ingress, or both
    if ! [[ "$direction" =~ ^(egress|ingress|both)$ ]]; then
        die "Invalid direction. Valid options are: egress, ingress, or both."
    fi        
}

# Function to remove the spaces around a value and set it in trimmed_value
trim_value() {
    trimmed_value="${1#"${1%%[![:space:]]*}"}"
    trimmed_value="${trimmed_value%"${trimmed_value##*[![:space:]]}"}"
}

# Function to clean up the values given by the user (command line, JSON file or profile) before they are
# validated: spaces around them are removed, and values that aren't case sensitive are lowercased
normalize_parameters() {
    local name
    for name in eth_interface profile latency jitter packet_loss duplicate corrupt reorder; do
        trim_value "${!name}"
        declare -g "$name=$trimmed_value"
    done
    for name in direction rate duration; do
        trim_value "${!name}"
        declare -g "$name=${trimmed_value,,}"
    done
}

# Function to validate the parameters and replace them with their normalized form
validate_arguments() {
    normalize_ip_list src
    normalize_ip_list dst
    local param
    for param in latency jitter packet_loss duplicate corrupt reorder; do
        [ -n "${!param}" ] && check_numeric "$param"
    done
    [ -n "$rate" ] && validate_rate "$rate"
    if [ -n "$duration" ]; then
        # die() inside $(...) only exits the subshell, so propagate the failure
        duration_seconds=$(parse_duration "$duration") || { echo "$duration_seconds"; exit 1; }
    fi
    warn_suspicious_parameters
}

# Function to warn about combinations that are accepted but probably not what was intended
warn_suspicious_parameters() {
    if [ -n "$jitter" ] && [ -n "$latency" ] && awk -v j="$jitter" -v l="$latency" 'BEGIN{exit !(j>l)}'; then
        echo "Warning: the jitter ($jitter ms) is larger than the latency ($latency ms)." >&2
    fi
    if [ -n "$reorder" ] && [ -z "$latency" ]; then
        echo "Warning: --reorder has no effect without --latency, packets are only reordered when some are delayed." >&2
    fi
}

# Function to validate and normalize a numeric parameter in place. Spaces and the unit (ms for latency and
# jitter, % for the percentages) are accepted and removed; the result has no leading or trailing zeros.
check_numeric() {
    local name="$1"
    local value="${!name}" unit="%" max=100
    case "$name" in
        latency|jitter) unit="ms"; max="" ;;
    esac

    trim_value "$value"
    value="${trimmed_value,,}"
    trim_value "${value%"$unit"}"
    value="$trimmed_value"
    if ! [[ "$value" =~ ^([0-9]+\.?[0-9]*|\.[0-9]+)$ ]] || ! awk -v v="$value" 'BEGIN{exit !(v>0)}'; then
        die "Invalid $name format. Use a positive numeric value for $name."
    fi
    if [ -n "$max" ] && ! awk -v v="$value" -v m="$max" 'BEGIN{exit !(v<=m)}'; then
        die "Invalid $name format. $name is a percentage and can't be more than $max."
    fi
    declare -g "$name=$(awk -v v="$value" 'BEGIN{OFMT="%.10g"; print v+0}')"
}

# Function to validate a bandwidth rate in tc units (e.g. 512kbit, 2mbit, 1gbit, 10mbps)
validate_rate() {
    if ! [[ "$1" =~ ^[0-9]+(\.[0-9]+)?(bit|kbit|mbit|gbit|bps|kbps|mbps|gbps)$ ]] || ! awk -v v="${1%%[a-z]*}" 'BEGIN{exit !(v>0)}'; then
        die "Invalid rate format. Use a positive number with a unit: bit, kbit, mbit, gbit (bits/s) or bps, kbps, mbps, gbps (bytes/s), e.g. 2mbit."
    fi
}

# Function to convert a duration (e.g. 90, 30s, 10m, 2h, 1d) to seconds
parse_duration() {
    local value="$1"
    [[ "$value" =~ ^([0-9]+)([smhd]?)$ ]] || die "Invalid duration format. Use a positive number with an optional unit: s, m, h or d (e.g. 30s, 10m, 2h)."
    local amount="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]:-s}"
    local -A factor=([s]=1 [m]=60 [h]=3600 [d]=86400)
    local seconds=$((10#$amount * ${factor[$unit]}))
    [ "$seconds" -gt 0 ] || die "Invalid duration format. The duration must be greater than zero."
    echo "$seconds"
}

# Function to validate the interface
validate_interface() {
    local interface="$1"
    if ! ip link show "$interface" &>/dev/null; then
        die "Invalid interface: $interface. Please provide a valid network interface."
    fi
}

# Function to process the --src_ip argument
validate_src_ip() {
    add_ip_entries src "$1"
}

# Function to process the --dst_ip argument
validate_dst_ip() {
    add_ip_entries dst "$1"
}

# Function to add the entries of --src_ip or --dst_ip ("ip[/len][:port[~port...]]", separated by commas) to the
# src_ip or dst_ip array as "ip[/len]:port" (port 0 means any). Spaces around entries are removed. The values themselves are
# validated later by normalize_ip_list; nothing is expanded by the shell or silently dropped here.
add_ip_entries() {
    local kind="$1" entries="$2"
    local -n list="${kind}_ip" raw="${kind}_ip_arg"
    local items=() ports=() entry ip port

    raw="${raw:+$raw,}$entries"
    IFS=',' read -ra items <<< "$entries"
    for entry in "${items[@]}"; do
        trim_value "$entry"
        entry="$trimmed_value"
        [ -z "$entry" ] && continue
        if [[ "$entry" == *:* ]]; then
            ip="${entry%%:*}"
            # The sentinel keeps empty ports ("ip:", "ip:80~") from being dropped by read
            IFS='~' read -ra ports <<< "${entry#*:}~x"
            unset 'ports[${#ports[@]}-1]'
            for port in "${ports[@]}"; do
                list+=("$ip:$port")
            done
        else
            list+=("$entry:0")
        fi
    done
}

# Function to validate one IPv4 address or network with an optional port ("ip", "ip/len", "ip:port",
# "ip/len:port") and set normalized_ip_entry to its canonical form: no leading zeros (so 010 isn't
# mistaken for octal) in the octets, the prefix length or the port. Nothing is evaluated before the
# value is known to be numeric.
normalize_ip_entry() {
    local value="$1" name="$2"
    local address="${value%%:*}" port="" length="" octets=() octet

    if [[ "$value" == *:* ]]; then
        port="${value#*:}"
        if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -gt 65535 ]; then
            die "Invalid $name format for port. Port '$port' is not in the range 0-65535."
        fi
        port=$((10#$port))
    fi
    if [[ "$address" == */* ]]; then
        length="${address#*/}"
        address="${address%%/*}"
        if ! [[ "$length" =~ ^[0-9]{1,2}$ ]] || [ "$((10#$length))" -gt 32 ]; then
            die "Invalid $name format for IP. Please use a valid IPv4 address or CIDR notation IPv4 network for $name and $value"
        fi
        length=$((10#$length))
    fi
    if ! [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        die "Invalid $name format for IP. Please use a valid IPv4 address or CIDR notation IPv4 network for $name and $value"
    fi
    IFS=. read -ra octets <<< "$address"
    for octet in "${octets[@]}"; do
        [ "$((10#$octet))" -le 255 ] || die "Invalid $name format for IP. Please use a valid IPv4 address or CIDR notation IPv4 network for $name and $value"
    done
    normalized_ip_entry="$((10#${octets[0]})).$((10#${octets[1]})).$((10#${octets[2]})).$((10#${octets[3]}))${length:+/$length}${port:+:$port}"
}

# Function to validate the src_ip or dst_ip entries, replace them with their normalized form and remove
# duplicates. The raw argument kept for persistence and snapshots is rebuilt from the cleaned entries.
normalize_ip_list() {
    local kind="$1" entry
    local -n list="${kind}_ip" raw="${kind}_ip_arg"
    local -A seen=()
    local cleaned=()

    for entry in "${list[@]}"; do
        [ -z "$entry" ] && continue
        normalize_ip_entry "$entry" "${kind}_ip"
        [ -n "${seen[$normalized_ip_entry]+set}" ] && continue
        seen[$normalized_ip_entry]=1
        cleaned+=("$normalized_ip_entry")
    done
    list=("${cleaned[@]}")
    [ -n "$raw" ] && raw=$(join_ip_entries "${cleaned[@]}")
}

# Function to join "ip:port" entries back into the --src_ip/--dst_ip syntax (ip1:80~443,ip2)
join_ip_entries() {
    local entry address port joined="" order=()
    local -A address_ports=()

    for entry in "$@"; do
        address="${entry%:*}"
        port="${entry##*:}"
        [ -z "${address_ports[$address]+set}" ] && order+=("$address")
        address_ports[$address]+="${address_ports[$address]:+~}$port"
    done
    for address in "${order[@]}"; do
        joined+="${joined:+,}$address"
        [ "${address_ports[$address]}" != "0" ] && joined+=":${address_ports[$address]}"
    done
    echo "$joined"
}

# Function to display parameters and results
display_params() {
    local stage="$1"

    echo 
    echo "$stage network perturbations with the following parameters:" 
    in_namespace && echo "  - Namespace: $LATENCYNINJA_NETNS_DESC"
    [ -n "$eth_interface" ] && echo "  - Interface: $eth_interface"   
    for sip in "${src_ip[@]}"; do
        [ -n "$sip" ] && echo "  - Source IP/Network: $sip"       
    done
    for dip in "${dst_ip[@]}"; do
        [ -n "$dip" ] && echo "  - Destination IP/Network: $dip"       
    done
    [ -n "$direction" ] && echo "  - Direction: $direction"   
    [ -n "$latency" ] && echo "  - Latency: $latency ms"
    [ -n "$jitter" ] && echo "  - Jitter: $jitter ms"
    [ -n "$packet_loss" ] && echo "  - Packet Loss: $packet_loss %"     
    [ -n "$duplicate" ] && echo "  - Duplication: $duplicate %"    
    [ -n "$corrupt" ] && echo "  - Corruption: $corrupt %"
    [ -n "$reorder" ] && echo "  - Reorder: $reorder %"
    [ -n "$rate" ] && echo "  - Rate: $rate"
    [ -n "$profile" ] && echo "  - Profile: $profile"
    [ -n "$duration" ] && echo "  - Duration: $duration (automatic rollback)"

    if [ "$stage" = "Applied" ]; then
        echo
        echo "To validate, run: sudo $0 --query$(namespace_hint)"
        echo "To rollback, run: sudo $0 --rollback --interface $eth_interface$(namespace_hint)"
    fi
    echo 
}

# Function to swap dst_ip and src_ip based on perspectice of rules
swap_ips_if_match() {  
    [ "${#src_ip[@]}" -eq 0 ] || [ "${#dst_ip[@]}" -eq 0 ] && return  # return if either array is empty

    for index in "${!dst_ip[@]}"; do
        extracted_ip="${dst_ip[$index]}"
        # Compare extracted IP with the local IP
        if [ "$extracted_ip" == "$local_ip" ]; then
            temp="${src_ip[$index]}"
            src_ip[$index]="${dst_ip[$index]}"
            dst_ip[$index]="$temp"
            ips_swapped=1          
        fi
    done
}