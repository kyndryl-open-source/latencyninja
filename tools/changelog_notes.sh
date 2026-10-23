#!/usr/bin/env bash
#
# Print the CHANGELOG.md entries of a version (used for GitHub release notes).
#
# Usage: tools/changelog_notes.sh [version]   (default: version.txt)

set -euo pipefail

cd "$(dirname "$0")/.."

version="${1:-$(tr -d '[:space:]' < version.txt)}"

awk -v header="CHANGELOG $version" '
    $0 == header { found = 1; next }
    found && /^CHANGELOG / { exit }
    found && NF { print }
    END { if (!found) exit 1 }
' CHANGELOG.md || { echo "No 'CHANGELOG $version' section in CHANGELOG.md" >&2; exit 1; }
