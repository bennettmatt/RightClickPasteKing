#!/usr/bin/env bash
#
# check.sh — RightClickPasteKing
#
# Static validation: everything verifiable without compiling. Runs in
# seconds, anywhere. release.sh runs this as its first gate; run it by
# hand any time:
#
#   ./check.sh
#
# Checks:
#   1. Localization completeness — every NSLocalizedString key in
#      Sources/L10n.swift exists in every Resources/*.lproj/Localizable.strings,
#      and vice versa (no orphans), and no literal \uXXXX escapes slipped in.
#   2. VERSION file is well-formed semver (X.Y.Z).
#   3. Info.plist carries a real Sparkle public key.
#   4. (Warning only) the __GITHUB_USER__ placeholder — fine during
#      development, fatal at release time; release.sh enforces that part.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FAIL=0

# ── 1. Localization ─────────────────────────────────────────────────────
echo "==> Localization completeness"
python3 - << 'EOF' || FAIL=1
import re, sys, glob, os

swift = open('Sources/L10n.swift', encoding='utf-8').read()
swift_keys = set(re.findall(r'NSLocalizedString\(\s*\n?\s*"([^"]+)"', swift))
if not swift_keys:
    print("  ERROR: no keys found in Sources/L10n.swift"); sys.exit(1)

lprojs = sorted(glob.glob('Resources/*.lproj/Localizable.strings'))
if not lprojs:
    print("  ERROR: no Localizable.strings files found"); sys.exit(1)

ok = True
for path in lprojs:
    lang = os.path.basename(os.path.dirname(path)).replace('.lproj', '')
    content = open(path, encoding='utf-8').read()
    keys = set(re.findall(r'^"([^"]+)"\s*=', content, re.M))
    missing = swift_keys - keys
    extra = keys - swift_keys
    if missing or extra:
        ok = False
        if missing: print(f"  {lang}: MISSING {sorted(missing)}")
        if extra:   print(f"  {lang}: ORPHANED {sorted(extra)}")
    if re.search(r'\\u[0-9a-fA-F]{4}', content):
        ok = False
        print(f"  {lang}: literal \\uXXXX escape — use the real character")

print(f"  {len(swift_keys)} keys x {len(lprojs)} languages " + ("OK" if ok else "FAILED"))
sys.exit(0 if ok else 1)
EOF

# ── 2. VERSION format ───────────────────────────────────────────────────
echo "==> VERSION format"
VERSION="$(tr -d ' \t\r\n' < VERSION)"
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "  $VERSION OK"
else
    echo "  ERROR: VERSION must be X.Y.Z, got '$VERSION'"
    FAIL=1
fi

# ── 3. Sparkle public key ───────────────────────────────────────────────
echo "==> Sparkle public key"
if grep -A1 "SUPublicEDKey" Sources/Info.plist | grep -q "<string>.\{40,\}</string>"; then
    echo "  present OK"
else
    echo "  ERROR: SUPublicEDKey missing or malformed in Sources/Info.plist"
    FAIL=1
fi

# ── 4. Placeholder (warning only) ───────────────────────────────────────
if grep -q "__GITHUB_USER__" Sources/Info.plist docs/index.html 2>/dev/null; then
    echo "==> NOTE: __GITHUB_USER__ placeholder present (fine for dev;"
    echo "    run ./configure-github.sh <username> before releasing)"
fi

echo ""
if [[ $FAIL -ne 0 ]]; then
    echo "check.sh: FAILED"
    exit 1
fi
echo "check.sh: all checks passed"
