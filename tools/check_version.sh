#!/usr/bin/env bash
#
# Check that version.txt was bumped relative to a base ref and that CHANGELOG.md documents it.
# Used by CI on pull requests to main; can be run locally before opening a PR.
#
# Usage: tools/check_version.sh [base-ref]   (default: origin/main)

set -euo pipefail

cd "$(dirname "$0")/.."

base_ref="${1:-origin/main}"
version=$(tr -d '[:space:]' < version.txt)
base=$(git show "$base_ref:version.txt" | tr -d '[:space:]')
status=0

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "::error file=version.txt::Invalid version '$version' (expected X.Y or X.Y.Z)"
    status=1
fi

if [ "$version" = "$base" ] || [ "$(printf '%s\n%s\n' "$base" "$version" | sort -V | tail -n1)" != "$version" ]; then
    echo "::error file=version.txt::version.txt ($version) must be greater than $base_ref ($base). Run tools/bump_version.sh"
    status=1
fi

notes=$("$(dirname "$0")/changelog_notes.sh" "$version" 2>/dev/null || true)
if ! grep -qE '^- +[^ ]' <<< "$notes"; then
    echo "::error file=CHANGELOG.md::CHANGELOG.md has no entries under 'CHANGELOG $version'"
    status=1
fi

[ "$status" -eq 0 ] && echo "Version $version (base $base) and CHANGELOG entry OK"
exit "$status"
