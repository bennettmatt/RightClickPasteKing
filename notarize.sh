#!/usr/bin/env bash
#
# notarize.sh — RightClickPasteKing
#
# One-command release pipeline for the Xcode project:
#   archive  ->  export (Developer ID)  ->  notarize  ->  staple  ->  DMG
#
# Produces a notarized, stapled DMG that anyone can download and open with
# no Gatekeeper friction. Run this instead of building manually in Xcode
# when you want a shippable release.
#
# ─────────────────────────────────────────────────────────────────────────
# ONE-TIME SETUP (do this once, ever, on your Mac):
#
#   1. Confirm your Developer ID Application certificate is installed:
#        security find-identity -v -p codesigning
#      You should see a line like:
#        "Developer ID Application: Matthew Bennett (E25J39RE3C)"
#      The 10-char code in parentheses is your Team ID — E25J39RE3C — and
#      it is already filled in as TEAM_ID below.
#
#   2. Create an app-specific password for notarytool:
#        - appleid.apple.com -> Sign-In & Security -> App-Specific Passwords
#        - Generate one, name it e.g. "notarytool"
#
#   3. Store credentials in the keychain under a profile name. notarytool
#      then reads them from the keychain and no secret ever lives in a file:
#        xcrun notarytool store-credentials "RCPK-notary" \
#          --apple-id "you@example.com" \
#          --team-id "E25J39RE3C" \
#          --password "the-app-specific-password-from-step-2"
#
#      "RCPK-notary" is the profile name this script expects (NOTARY_PROFILE
#      below). Change both if you prefer a different name.
# ─────────────────────────────────────────────────────────────────────────
#
# EVERY-RELEASE WORKFLOW:
#
#   ./regenerate.sh      # only if VERSION / project.yml / sources changed
#   ./notarize.sh
#
# Output:
#   dist/RightClickPasteKing-<version>.dmg   <- this is what you distribute
#
# The DMG is stapled, so it works even on machines that are offline when
# they first open it.

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────
APP_NAME="RightClickPasteKing"
SCHEME="RightClickPasteKing"

# Apple Developer Team ID. Used for the export options plist and recorded
# here as the canonical reference for the project.
TEAM_ID="E25J39RE3C"

# The keychain profile created during one-time setup (step 3 above).
# Override at the command line if you used a different name:
#   NOTARY_PROFILE="my-profile" ./notarize.sh
NOTARY_PROFILE="${NOTARY_PROFILE:-RCPK-notary}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="$SCRIPT_DIR/$APP_NAME.xcodeproj"
DIST_DIR="$SCRIPT_DIR/dist"
ARCHIVE_PATH="$DIST_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$DIST_DIR/export"
APP_BUNDLE="$EXPORT_DIR/$APP_NAME.app"

# ── Preconditions ───────────────────────────────────────────────────────

# The Xcode project must exist. It is generated from project.yml — it is
# not committed — so a fresh checkout needs ./regenerate.sh first.
if [[ ! -d "$PROJECT" ]]; then
    echo "ERROR: $APP_NAME.xcodeproj not found." >&2
    echo "The Xcode project is generated from project.yml. Run:" >&2
    echo "  ./regenerate.sh" >&2
    exit 1
fi

# A "Developer ID Application" certificate must exist in the keychain.
# This is DISTINCT from an "Apple Development" certificate: the latter is
# for local development only and is NOT trusted by Gatekeeper on other
# Macs — notarization rejects it.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if ! echo "$IDENTITIES" | grep -q "Developer ID Application"; then
    echo "ERROR: no 'Developer ID Application' certificate found in the keychain." >&2
    echo "" >&2
    if echo "$IDENTITIES" | grep -q "Apple Development"; then
        echo "You have an 'Apple Development' certificate, but that one is for" >&2
        echo "local development only — Gatekeeper does not trust it on other" >&2
        echo "Macs and notarization will reject it." >&2
        echo "" >&2
    fi
    echo "Create a Developer ID Application certificate first:" >&2
    echo "  - developer.apple.com -> Certificates -> + -> Developer ID Application" >&2
    echo "  - or Xcode -> Settings -> Accounts -> Manage Certificates -> +" >&2
    echo "" >&2
    echo "It must also be present in the local keychain WITH its private key" >&2
    echo "for Xcode to sign with it." >&2
    exit 1
fi

# Clean any previous run's output so stale artifacts can't be mistaken for
# fresh ones.
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$DIST_DIR"

# ── Step 1: archive ─────────────────────────────────────────────────────
# A Release archive of the app. Signing settings (Developer ID, Hardened
# Runtime, Team ID) come from project.yml, so no signing flags are needed
# here — xcodebuild uses the project's configured manual signing.
echo "==> Archiving ($SCHEME, Release)"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    | grep -E "^(=== |\*\* |error:|warning:)" || true

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "ERROR: archive failed — $ARCHIVE_PATH was not produced." >&2
    echo "Re-run the xcodebuild archive command above without the grep" >&2
    echo "filter to see the full output." >&2
    exit 1
fi

# ── Step 2: export ──────────────────────────────────────────────────────
# Export the archive as a Developer ID-signed app. The export needs an
# options plist; we generate it inline so there's no extra file to keep in
# sync with the Team ID.
EXPORT_PLIST="$(mktemp -t rcpk-exportoptions)"
trap 'rm -f "$EXPORT_PLIST"' EXIT
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST

echo "==> Exporting Developer ID build"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    | grep -E "^(=== |\*\* |error:|warning:)" || true

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: export failed — $APP_BUNDLE was not produced." >&2
    exit 1
fi

# Sanity-check the signature is a real Developer ID one (not ad-hoc).
SIGN_INFO="$(codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 || true)"
if echo "$SIGN_INFO" | grep -q "Signature=adhoc"; then
    echo "ERROR: exported app is ad-hoc signed, not Developer ID signed." >&2
    echo "Check the signing settings in project.yml and re-run ./regenerate.sh." >&2
    exit 1
fi

# Read the version out of the exported bundle so the DMG is named for it.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.0")"
echo "==> Exported $APP_NAME $VERSION"

# ── Step 3: notarize ────────────────────────────────────────────────────
# notarytool wants a zip (or dmg/pkg). We zip with ditto, which preserves
# the bundle structure and signature correctly — a plain `zip` can mangle it.
SUBMIT_ZIP="$DIST_DIR/$APP_NAME-submit.zip"
rm -f "$SUBMIT_ZIP"
echo "==> Zipping for notarization"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$SUBMIT_ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
set +e
SUBMIT_OUTPUT="$(xcrun notarytool submit "$SUBMIT_ZIP" \
                    --keychain-profile "$NOTARY_PROFILE" \
                    --wait 2>&1)"
SUBMIT_STATUS=$?
set -e
echo "$SUBMIT_OUTPUT"

if [[ $SUBMIT_STATUS -ne 0 ]] || ! echo "$SUBMIT_OUTPUT" | grep -q "status: Accepted"; then
    echo "" >&2
    echo "ERROR: notarization did not succeed." >&2
    if echo "$SUBMIT_OUTPUT" | grep -qi "keychain\|profile\|credential"; then
        echo "This looks like a credentials problem. Confirm the keychain" >&2
        echo "profile '$NOTARY_PROFILE' exists — see ONE-TIME SETUP step 3" >&2
        echo "at the top of this script." >&2
    fi
    # Try to extract the submission ID and dump the detailed log.
    SUBMISSION_ID="$(echo "$SUBMIT_OUTPUT" | awk '/id: / {print $2; exit}')"
    if [[ -n "${SUBMISSION_ID:-}" ]]; then
        echo "==> Fetching detailed log for submission $SUBMISSION_ID:" >&2
        xcrun notarytool log "$SUBMISSION_ID" \
            --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
fi

rm -f "$SUBMIT_ZIP"

# ── Step 4: staple ──────────────────────────────────────────────────────
# Stapling embeds the notarization ticket in the bundle so Gatekeeper can
# verify it even with no network connection.
echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

# ── Step 5: build the distributable DMG ─────────────────────────────────
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"

echo "==> Building DMG"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

# Copy the stapled app and add the conventional /Applications shortcut so
# the user can drag-to-install.
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

# ── Step 6: sign + staple the DMG itself ────────────────────────────────
# Signing the DMG means the download container is trusted too. We reuse the
# Developer ID identity from the app's own signature.
DMG_IDENTITY="$(codesign --display --verbose=2 "$APP_BUNDLE" 2>&1 \
                | awk -F'Authority=' '/Authority=Developer ID Application/ {print $2; exit}')"
if [[ -n "${DMG_IDENTITY:-}" ]]; then
    echo "==> Signing the DMG ($DMG_IDENTITY)"
    codesign --force --sign "$DMG_IDENTITY" --timestamp "$DMG_PATH"
    # A signed DMG can also be stapled — belt and suspenders.
    xcrun stapler staple "$DMG_PATH" || true
else
    echo "    NOTE: could not auto-detect the Developer ID to sign the DMG."
    echo "    The app inside is fully notarized and stapled regardless;"
    echo "    signing the DMG container is optional polish."
fi

# Tidy up the intermediate archive/export now that the DMG exists.
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

echo ""
echo "==> Done."
echo "    Distributable: $DMG_PATH"
echo ""
echo "Verification (optional, recommended once):"
echo "    spctl --assess --type open --context context:primary-signature -v \"$DMG_PATH\""
echo "    Should report: accepted / source=Notarized Developer ID"
echo ""
echo "Hand that .dmg to anyone — they drag the app to /Applications and it"
echo "opens with no Gatekeeper warning. On first launch they still grant"
echo "Accessibility permission once (that's a per-user choice, not a"
echo "signing issue) — the in-app Setup Guide walks them through it."
