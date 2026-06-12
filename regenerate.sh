#!/usr/bin/env bash
#
# regenerate.sh — RightClickPasteKing
#
# Generates RightClickPasteKing.xcodeproj from project.yml using XcodeGen,
# with the version numbers injected from the VERSION file.
#
# Run this:
#   - after a fresh checkout (the .xcodeproj is not committed)
#   - after editing VERSION
#   - after editing project.yml
#   - after adding/removing source files (XcodeGen re-scans Sources/)
#
# Usage:
#   ./regenerate.sh
#
# Requires XcodeGen:  brew install xcodegen
#
# ── How versioning works ────────────────────────────────────────────────
# VERSION (a plain text file at the project root) is the single source of
# truth for the human-facing version, e.g. "1.0.0".
#
# This script reads VERSION, generates a monotonic build number (a UTC
# timestamp YYYYMMDDHHMM), and writes both into a temporary copy of
# project.yml — replacing the placeholder MARKETING_VERSION and
# CURRENT_PROJECT_VERSION values — before invoking XcodeGen. The committed
# project.yml keeps its placeholders and stays diff-clean.
#
# Xcode then expands $(MARKETING_VERSION) / $(CURRENT_PROJECT_VERSION) in
# Info.plist at build time. So: edit VERSION, run ./regenerate.sh, build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Preconditions ───────────────────────────────────────────────────────
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found." >&2
    echo "Install it with:  brew install xcodegen" >&2
    exit 1
fi

VERSION_FILE="$SCRIPT_DIR/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi

PROJECT_SPEC="$SCRIPT_DIR/project.yml"
if [[ ! -f "$PROJECT_SPEC" ]]; then
    echo "ERROR: project.yml not found at $PROJECT_SPEC" >&2
    exit 1
fi

# ── Resolve version strings ─────────────────────────────────────────────
SHORT_VERSION="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
if [[ -z "$SHORT_VERSION" ]]; then
    echo "ERROR: VERSION file is empty" >&2
    exit 1
fi
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

echo "==> Version $SHORT_VERSION (build $BUILD_NUMBER)"

# ── Inject version into a temp copy of project.yml ──────────────────────
# The placeholders in project.yml are:
#   MARKETING_VERSION: "0.0.0"
#   CURRENT_PROJECT_VERSION: "000000000000"
# We replace the placeholder VALUES specifically (matching the quoted
# placeholder strings) so nothing else in the file is touched.
#
# IMPORTANT: XcodeGen resolves source/resource paths RELATIVE TO THE SPEC
# FILE's directory. So the temp spec must live in the project root, not in
# /tmp — otherwise Sources/ and Resources/ wouldn't be found. We write it
# as a dotfile in the project root and clean it up on exit.
TMP_SPEC="$SCRIPT_DIR/.project.generated.yml"
trap 'rm -f "$TMP_SPEC"' EXIT

sed -e "s/MARKETING_VERSION: \"0.0.0\"/MARKETING_VERSION: \"$SHORT_VERSION\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \"000000000000\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" \
    "$PROJECT_SPEC" > "$TMP_SPEC"

# Sanity check: confirm both substitutions actually happened. If a
# placeholder survived, project.yml was edited and the placeholder changed —
# fail loudly rather than generate a project with a bogus version.
if grep -q 'MARKETING_VERSION: "0.0.0"' "$TMP_SPEC" \
   || grep -q 'CURRENT_PROJECT_VERSION: "000000000000"' "$TMP_SPEC"; then
    echo "ERROR: version placeholder not found in project.yml — did the" >&2
    echo "       placeholder text change? Expected:" >&2
    echo '         MARKETING_VERSION: "0.0.0"' >&2
    echo '         CURRENT_PROJECT_VERSION: "000000000000"' >&2
    exit 1
fi

# ── Generate the Xcode project ──────────────────────────────────────────
echo "==> Running XcodeGen"
xcodegen generate --spec "$TMP_SPEC" --project "$SCRIPT_DIR"

echo ""
echo "==> Done: RightClickPasteKing.xcodeproj"
echo ""
echo "Next:"
echo "  open RightClickPasteKing.xcodeproj"
echo "  then build/run the RightClickPasteKing scheme."
echo ""
echo "To ship a notarized build, see ./notarize.sh"
