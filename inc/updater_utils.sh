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

# Function to update from repo
check_version() {
  local repo_url="$1"
  local version_file="$2"
  
  # Check for git
  if ! command -v git &> /dev/null
  then
    echo "git could not be found. Please install it to proceed."
    return 1
  fi

  # Clone the repo to a temporary directory
  local tmp_dir
  tmp_dir=$(mktemp -d)
  git clone "$repo_url" "$tmp_dir" &> /dev/null
  
  if [ $? -ne 0 ]; then
    echo "Failed to clone the repository. Please check the URL and try again."
    return 1
  fi
  
  # Get the latest version from the repo
  local latest_version
  latest_version=$(cat "$tmp_dir/$version_file")
  
  # Remove the temporary directory
  rm -rf "$tmp_dir"
  
  # Get the current version
  if [ ! -f "$version_file" ]; then
    echo "Version file not found in the current folder."
    return 1
  fi
  local current_version
  current_version=$(cat "$version_file")
  
  # Compare versions
  if [ "$(printf "%s\n%s" "$current_version" "$latest_version" | sort -V | head -n 1)" = "$current_version" ]; then
    if [ "$latest_version" = "$current_version" ]; then
      echo "You are using the latest version."
    else
      echo "A new version is available."
      echo "Latest version: $latest_version"
      echo "Current version: $current_version"
      return 0
    fi
  else
    echo "Your version is newer than the latest version in the repository. No update needed."
  fi
  return 1
}

update_repo() {
  local repo_dir="$1"
  
  # Check for git
  if ! command -v git &> /dev/null
  then
    echo "git could not be found. Please install it to proceed."
    return 1
  fi
  
  # Navigate to the repository directory
  cd "$repo_dir" || return 1
  
  # Update the repository
  git pull &> /dev/null
  if [ $? -ne 0 ]; then
    echo "Failed to update the repository. Please check the URL and try again."
    return 1
  fi
  
  echo "Update successful!"
}

update(){
  if check_version $repo $version_file; then
    read -p "Do you want to update to the latest version? (y/n) " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
      update_repo $repo
      else
      echo "Update cancelled."
    fi
  fi
}