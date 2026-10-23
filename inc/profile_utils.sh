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

# Profiles are JSON files with the same perturbation keys as --json (latency, jitter, packet_loss,
# duplicate, corrupt, reorder, rate) plus a "description". Latency and jitter are round-trip values,
# like the command line options. Files in $user_profiles_dir override the built-in ones.

# Function to find the file of a profile
profile_file() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    if [ -f "$user_profiles_dir/$name.json" ]; then
        echo "$user_profiles_dir/$name.json"
    elif [ -f "$profiles_dir/$name.json" ]; then
        echo "$profiles_dir/$name.json"
    else
        return 1
    fi
}

# Function to fill in parameters that weren't given explicitly from a profile
load_profile() {
    local name="$1"
    local file key value

    file=$(profile_file "$name") || die "Unknown profile: $name. Use --profiles to list the available profiles."
    $jq_path -e 'type == "object"' "$file" &>/dev/null || die "Invalid profile file: $file"
    local unknown
    unknown=$($jq_path -r 'keys - ["description", "latency", "jitter", "packet_loss", "duplicate", "corrupt", "reorder", "rate"] | join(", ")' "$file")
    [ -n "$unknown" ] && die "Unknown key(s) in profile $file: $unknown. Valid keys: description latency jitter packet_loss duplicate corrupt reorder rate"

    for key in latency jitter packet_loss duplicate corrupt reorder rate; do
        value=$($jq_path -r --arg k "$key" '.[$k] // empty' "$file")
        # Explicit command line or JSON values take precedence over the profile
        [ -n "$value" ] && [ -z "${!key}" ] && declare -g "$key=$value"
    done
}

# Function to list the available profiles
list_profiles() {
    local file name description values origin
    declare -A seen=()

    echo
    echo "Available profiles (use with --profile <name>; explicit options override profile values):"
    echo
    for file in "$user_profiles_dir"/*.json "$profiles_dir"/*.json; do
        [ -f "$file" ] || continue
        name=$(basename "$file" .json)
        [ -n "${seen[$name]+set}" ] && continue
        seen[$name]=1
        [[ "$file" == "$user_profiles_dir"/* ]] && origin=" (custom)" || origin=""
        description=$($jq_path -r '.description // ""' "$file")
        values=$($jq_path -r '[
            (if .latency then "latency \(.latency)ms" else empty end),
            (if .jitter then "jitter \(.jitter)ms" else empty end),
            (if .packet_loss then "loss \(.packet_loss)%" else empty end),
            (if .duplicate then "duplicate \(.duplicate)%" else empty end),
            (if .corrupt then "corrupt \(.corrupt)%" else empty end),
            (if .reorder then "reorder \(.reorder)%" else empty end),
            (if .rate then "rate \(.rate)" else empty end)
        ] | join(", ")' "$file")
        printf "  %-16s %s%s\n" "$name" "$description" "$origin"
        printf "  %-16s %s\n" "" "$values"
    done
    echo
    echo "Custom profiles can be added to $user_profiles_dir/<name>.json"
    echo
}
