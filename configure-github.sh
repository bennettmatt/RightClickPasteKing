#!/usr/bin/env bash
#
# configure-github.sh — RightClickPasteKing
#
# One-time setup: stamps your GitHub username into the two files that need
# it (the Sparkle feed URL in Info.plist and the links on the download
# page). Run once, before the first release:
#
#   ./configure-github.sh yourgithubusername
#
# The Sparkle feed URL is baked into every shipped build — once the first
# public release is out, the username and repo name are effectively frozen
# (changing them would orphan existing installs' update checks).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PLACEHOLDER="__GITHUB_USER__"
FILES=("Sources/Info.plist" "docs/index.html")

if [[ $# -ne 1 || -z "${1:-}" ]]; then
    echo "Usage: ./configure-github.sh <github-username>" >&2
    exit 1
fi
USERNAME="$1"

# Sanity: GitHub usernames are alphanumerics and hyphens.
if ! [[ "$USERNAME" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "ERROR: '$USERNAME' doesn't look like a GitHub username." >&2
    exit 1
fi

FOUND_ANY=0
for f in "${FILES[@]}"; do
    if grep -q "$PLACEHOLDER" "$f"; then
        # BSD sed (macOS) requires the '' after -i.
        sed -i '' "s/$PLACEHOLDER/$USERNAME/g" "$f"
        echo "Stamped $USERNAME into $f"
        FOUND_ANY=1
    fi
done

if [[ $FOUND_ANY -eq 0 ]]; then
    echo "Nothing to do — no $PLACEHOLDER placeholders found."
    echo "Current feed URL:"
    grep -A1 "SUFeedURL" Sources/Info.plist | grep "<string>" || true
    exit 0
fi

echo ""
echo "Done. Feed URL is now:"
grep -A1 "SUFeedURL" Sources/Info.plist | grep "<string>" || true
echo ""
echo "Next: ./regenerate.sh, then ./release.sh for the first release."
