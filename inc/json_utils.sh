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

# Keys accepted in --json files: every option that applies rules. Values can be strings or numbers,
# src_ip/dst_ip can also be arrays, and persist is a boolean. Values in the file override the same
# options given on the command line. container/netns/pid are handled before entering the namespace
# (see json_namespace_target in namespace_utils.sh).
declare -g -a json_keys=(interface src_ip dst_ip direction latency jitter packet_loss duplicate corrupt reorder rate
    profile duration persist backup logging container netns pid)

# Function to load the options from a JSON file
load_json_file() {
    local file="$1"
    local error unknown wrong_type key value known

    [ -r "$file" ] || die "JSON file not found: $file"
    error=$($jq_path -e 'type == "object"' "$file" 2>&1 >/dev/null) || die "Invalid JSON file $file: ${error:-the top level must be an object}"

    known=$(printf '%s\n' "${json_keys[@]}" | $jq_path -R . | $jq_path -s -c .)
    unknown=$($jq_path -r --argjson known "$known" 'keys - $known | join(", ")' "$file")
    [ -n "$unknown" ] && die "Unknown key(s) in JSON file $file: $unknown. Valid keys: ${json_keys[*]}"

    wrong_type=$($jq_path -r '[to_entries[] | select(
            (.key == "src_ip" or .key == "dst_ip") as $list
            | (.value | type) as $t
            | ($t == "object") or ($t == "array" and ($list | not)) or ($t == "boolean" and .key != "persist")
        ) | .key] | join(", ")' "$file")
    [ -n "$wrong_type" ] && die "Invalid value type for $wrong_type in JSON file $file. Use strings or numbers (arrays for src_ip/dst_ip, true/false for persist)."

    for key in "${json_keys[@]}"; do
        value=$($jq_path -r --arg k "$key" '.[$k] | if . == null then empty elif type == "array" then map(tostring) | join(",") else tostring end' "$file")
        [ -z "$value" ] && continue
        case "$key" in
            interface) eth_interface="$value"; interface_provided=1 ;;
            src_ip) validate_src_ip "$value" ;;
            dst_ip) validate_dst_ip "$value" ;;
            persist)
                case "$value" in
                    true) persist=1 ;;
                    false) ;;
                    *) die "Invalid value for persist in JSON file $file: $value. Use true or false." ;;
                esac ;;
            backup) backup_dir="$value" ;;
            logging) log_file="$value" ;;
            container|netns|pid) ;;
            *) declare -g "$key=$value" ;;
        esac
    done
}
