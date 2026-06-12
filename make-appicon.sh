#!/usr/bin/env bash
#
# make-appicon.sh — RightClickPasteKing
#
# Regenerates the Xcode asset-catalog app icon set
# (Resources/Assets.xcassets/AppIcon.appiconset/) from a single 1024x1024
# PNG master. Run this only when the icon artwork changes.
#
# Usage:
#   ./make-appicon.sh                       # uses icon/icon-1024.png
#   ./make-appicon.sh path/to/master.png    # uses a specific master PNG
#
# Requires macOS (uses the built-in `sips` tool).
#
# After running, the new icons are picked up by the next Xcode build — no
# need to re-run regenerate.sh (the asset catalog path in project.yml is
# unchanged; only its contents differ).
#
# To use your own artwork: replace icon/icon-1024.png with a 1024x1024 RGBA
# PNG and re-run. The master must be square — macOS app icons cannot be
# rectangular.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Resolve the master PNG ──────────────────────────────────────────────
MASTER="${1:-icon/icon-1024.png}"
if [[ ! -f "$MASTER" ]]; then
    echo "ERROR: master PNG not found: $MASTER" >&2
    echo "Provide a 1024x1024 PNG, or place one at icon/icon-1024.png" >&2
    exit 1
fi

# Verify it is exactly 1024x1024.
DIMS="$(sips -g pixelWidth -g pixelHeight "$MASTER" \
        | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w"x"h}')"
if [[ "$DIMS" != "1024x1024" ]]; then
    echo "ERROR: master must be exactly 1024x1024, got $DIMS ($MASTER)" >&2
    exit 1
fi

# ── Regenerate the .appiconset PNGs ─────────────────────────────────────
ICONSET_DIR="$SCRIPT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"
if [[ ! -d "$ICONSET_DIR" ]]; then
    echo "ERROR: asset catalog icon set not found at:" >&2
    echo "  $ICONSET_DIR" >&2
    echo "The asset catalog structure is part of the repo; if it's missing," >&2
    echo "restore it from version control." >&2
    exit 1
fi

# The filenames here MUST match what Contents.json references. The macOS
# app icon set: base sizes 16/32/128/256/512, each at @1x and @2x.
# Filename : pixel size
declare -a SPECS=(
    "icon_16.png 16"
    "icon_32.png 32"
    "icon_32_1x.png 32"
    "icon_64.png 64"
    "icon_128.png 128"
    "icon_256.png 256"
    "icon_256_1x.png 256"
    "icon_512.png 512"
    "icon_512_1x.png 512"
    "icon_1024.png 1024"
)

echo "==> Regenerating AppIcon set from $MASTER"
for spec in "${SPECS[@]}"; do
    name="${spec% *}"
    size="${spec#* }"
    sips -z "$size" "$size" "$MASTER" --out "$ICONSET_DIR/$name" >/dev/null
    echo "    $name (${size}x${size})"
done

# Keep the editable standalone copies in icon/ in sync too, for READMEs/web.
for size in 1024 512 256 128; do
    sips -z "$size" "$size" "$MASTER" --out "$SCRIPT_DIR/icon/icon-$size.png" >/dev/null
done

echo ""
echo "==> Done. The new icons are in:"
echo "    $ICONSET_DIR"
echo "    They'll be picked up by the next Xcode build."
