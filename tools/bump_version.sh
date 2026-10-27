#!/usr/bin/env bash
#
# Start a new Latency Ninja version: updates version.txt. The CHANGELOG entry is written by hand.
#
# Usage:
#   tools/bump_version.sh [minor|major|X.Y] [--branch]
#
#   minor     1.22 -> 1.23 (default)
#   major     1.22 -> 2.0
#   X.Y       explicit version
#   --branch  create the version branch (named X.Y, the project convention) from origin/main first
#
# The new version is computed from origin/main's version.txt so running it twice is safe.

set -euo pipefail

cd "$(dirname "$0")/.."

bump="minor" create_branch=0
for arg in "$@"; do
    case "$arg" in
        --branch) create_branch=1 ;;
        minor|major) bump="$arg" ;;
        [0-9]*.[0-9]*) bump="$arg" ;;
        *) sed -n '3,13p' "$0"; exit 1 ;;
    esac
done

git fetch -q origin main 2>/dev/null || echo "Warning: could not fetch origin/main, using the local copy." >&2
base=$(git show origin/main:version.txt 2>/dev/null || cat version.txt)
IFS=. read -r major minor _ <<< "$base"

case "$bump" in
    minor) new="$major.$((minor + 1))" ;;
    major) new="$((major + 1)).0" ;;
    *) new="$bump" ;;
esac

if [ "$(printf '%s\n%s\n' "$base" "$new" | sort -V | tail -n1)" != "$new" ] || [ "$base" = "$new" ]; then
    echo "New version $new must be greater than the released version $base." >&2
    exit 1
fi

if [ "$create_branch" -eq 1 ]; then
    git switch -c "$new" --no-track origin/main
fi

echo "$new" > version.txt

echo "Version bumped: $base -> $new"
echo "Next: add a 'CHANGELOG $new' section at the top of CHANGELOG.md (CI requires it), then open a PR to main."
