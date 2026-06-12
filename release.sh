#!/usr/bin/env bash
#
# release.sh — RightClickPasteKing
#
# One-command public release:
#
#   VERSION file says X.Y.Z
#   ./release.sh
#
#   1. regenerates the Xcode project (fresh build number)
#   2. runs notarize.sh (archive -> export -> notarize -> staple -> DMG)
#   3. creates GitHub release vX.Y.Z and uploads the DMG
#   4. signs the update and regenerates docs/appcast.xml (generate_appcast,
#      using the ed25519 key in your keychain)
#   5. commits the appcast and pushes — making the update visible to
#      installed apps via GitHub Pages
#
# ── One-time prerequisites ──────────────────────────────────────────────
#   * ./configure-github.sh <username>     (stamps the Sparkle feed URL)
#   * brew install gh && gh auth login     (GitHub CLI, authenticated)
#   * brew install --cask sparkle          (generate_appcast + keychain key
#                                           from generate_keys)
#   * GitHub Pages enabled: repo Settings -> Pages -> branch main, /docs
#
# ── Appcast scope note ──────────────────────────────────────────────────
# The appcast is regenerated containing ONLY the newest version. Sparkle
# just needs the latest entry to offer updates; keeping every historical
# DMG around would only enable delta updates, which are pointless for a
# ~5 MB download. The staging dir is rebuilt fresh each release.

set -euo pipefail

APP_NAME="RightClickPasteKing"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Preconditions ───────────────────────────────────────────────────────

# Feed URL must be configured (placeholder stamped with the real username).
if grep -q "__GITHUB_USER__" Sources/Info.plist; then
    echo "ERROR: the Sparkle feed URL still has the __GITHUB_USER__ placeholder." >&2
    echo "Run:  ./configure-github.sh <your-github-username>" >&2
    exit 1
fi

# GitHub CLI present and authenticated.
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI (gh) not found.  brew install gh && gh auth login" >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated.  Run: gh auth login" >&2
    exit 1
fi

# The git remote tells us the user/repo — no hardcoding.
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$ORIGIN_URL" ]]; then
    echo "ERROR: no git 'origin' remote. Push this repo to GitHub first." >&2
    exit 1
fi
# Handles both git@github.com:user/repo.git and https://github.com/user/repo
GH_PATH="$(echo "$ORIGIN_URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
GH_USER="${GH_PATH%%/*}"
GH_REPO="${GH_PATH##*/}"
if [[ -z "$GH_USER" || -z "$GH_REPO" ]]; then
    echo "ERROR: couldn't parse user/repo from origin URL: $ORIGIN_URL" >&2
    exit 1
fi

# Sparkle's generate_appcast, wherever the cask put it (path discovered
# fresh so a future `brew upgrade --cask sparkle` doesn't break us).
GENERATE_APPCAST="$(find "$(brew --prefix)/Caskroom/sparkle" -name generate_appcast -type f -not -path "*dSYM*" 2>/dev/null | head -1)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "ERROR: generate_appcast not found.  brew install --cask sparkle" >&2
    exit 1
fi

VERSION="$(tr -d ' \t\r\n' < VERSION)"
TAG="v$VERSION"
DMG="dist/$APP_NAME-$VERSION.dmg"

echo "==> Releasing $APP_NAME $VERSION as $GH_USER/$GH_REPO $TAG"

# Refuse to re-release an existing tag — bump VERSION instead.
if gh release view "$TAG" --repo "$GH_USER/$GH_REPO" >/dev/null 2>&1; then
    echo "ERROR: release $TAG already exists on GitHub." >&2
    echo "Bump the VERSION file and run again." >&2
    exit 1
fi

# ── 1+2. Build, notarize, package ───────────────────────────────────────
./regenerate.sh
./notarize.sh

if [[ ! -f "$DMG" ]]; then
    echo "ERROR: expected $DMG was not produced by notarize.sh" >&2
    exit 1
fi

# ── 3. GitHub release ───────────────────────────────────────────────────
echo "==> Creating GitHub release $TAG"
gh release create "$TAG" "$DMG" \
    --repo "$GH_USER/$GH_REPO" \
    --title "$APP_NAME $VERSION" \
    --notes "Signed and notarized. Existing installs update in-app via Sparkle."

# ── 4. Signed appcast ───────────────────────────────────────────────────
# Stage exactly one DMG (the new one) and generate the appcast against the
# GitHub release asset URL for this tag. generate_appcast signs it with
# the ed25519 key in the keychain (created by generate_keys).
echo "==> Generating signed appcast"
STAGING="$SCRIPT_DIR/.appcast-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp "$DMG" "$STAGING/"

"$GENERATE_APPCAST" "$STAGING" \
    --download-url-prefix "https://github.com/$GH_USER/$GH_REPO/releases/download/$TAG/"

if [[ ! -f "$STAGING/appcast.xml" ]]; then
    echo "ERROR: generate_appcast did not produce appcast.xml" >&2
    exit 1
fi
cp "$STAGING/appcast.xml" docs/appcast.xml
rm -rf "$STAGING"

# ── 5. Publish the appcast ──────────────────────────────────────────────
echo "==> Committing and pushing the appcast"
git add docs/appcast.xml
git commit -m "Appcast for $TAG"
git push

echo ""
echo "==> Released $APP_NAME $VERSION."
echo "    Download page: https://$GH_USER.github.io/$GH_REPO/"
echo "    Release:       https://github.com/$GH_USER/$GH_REPO/releases/tag/$TAG"
echo ""
echo "GitHub Pages takes a minute or two to redeploy the appcast; installed"
echo "apps will see the update on their next check after that."
