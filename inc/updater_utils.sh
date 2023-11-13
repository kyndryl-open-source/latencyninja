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

# Function to check the current and last version fron Github
check_version() {
    local version_url="$1"
    local version_file="$2"
    
    echo "$app_name Updater - BETA"

    # Get the latest version from the URL
    local latest_version
    latest_version=$($curl_path -sL "$version_url") || die "Failed to fetch the latest version. Please check the URL and try again."

    # Get the current version
    if [ ! -f "$version_file" ]; then
        die "Version file not found in the current folder."
    fi

    local current_version
    current_version=$(cat "$version_file") || die "Failed to read the version file."

    # Compare versions
    if [ "$latest_version" = "$current_version" ]; then
        echo "You are using the latest version: $current_version."
        return 1
    elif [ "$(printf "%s\n%s" "$latest_version" "$current_version" | sort -V | tail -n1)" = "$latest_version" ]; then
        echo "A new version is available."
        echo "Latest version: $latest_version"
        echo "Current version: $current_version"
        return 0
    else
        echo "Your version is already the latest version. No update needed."
        return 1
    fi
}

# Function to perform the update
update_repo() {
    local repo_dir="$1"
    
    sudo -u "$SUDO_USER" $git_path pull &> /dev/null || die "Failed to update the repository. Please check the URL and try again."
    echo "$app_name updated successfully!"
}

# Function to perform update
update() {
    if check_version $version_url $version_file; then
        read -p "Do you want to update to the latest version? (y/n) " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            update_repo $repo_url
        else
            echo "Update cancelled."
        fi
    fi
}