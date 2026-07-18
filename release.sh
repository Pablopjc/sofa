#!/bin/bash
# Builds, verifies and publishes a source-matched Sofa release. The app's
# "Check for Updates…" reads the latest non-draft GitHub release.
# Usage: ./release.sh 0.1.30 "What changed"
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
NOTES="${2:-}"

if [ -z "$VERSION" ]; then
  echo "usage: ./release.sh <version> [release notes]"
  echo "   eg: ./release.sh 2.1.0 \"Apple TV support and faster sync\""
  exit 1
fi

if ! command -v gh > /dev/null; then
  echo "✗ GitHub CLI not installed. Run:  brew install gh && gh auth login"
  exit 1
fi

if ! command -v git > /dev/null || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "✗ Run this from Sofa's Git repository."
  exit 1
fi

REPO=$(/usr/libexec/PlistBuddy -c "Print :SofaUpdateRepo" Info.plist 2>/dev/null || echo "")
if [ -z "$REPO" ] || [[ "$REPO" == *OWNER* ]]; then
  echo "✗ Set SofaUpdateRepo in Info.plist to your \"user/repo\" first."
  exit 1
fi

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [ "$CURRENT" != "$VERSION" ]; then
  echo "✗ Info.plist is version $CURRENT, not $VERSION. Bump the source first."
  exit 1
fi

# A release must be reproducible from the exact public source revision behind
# its tag. Refuse to publish a binary assembled from uncommitted or unpushed
# files (the failure mode that made the historical 0.1.24 tag incomplete).
if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo "✗ The source tree is not clean. Commit every source file before releasing."
  git status --short
  exit 1
fi

BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "master" ]; then
  echo "✗ Releases must be created from master (currently $BRANCH)."
  exit 1
fi

echo "▸ Verifying the public source revision…"
git fetch origin master --tags
HEAD_COMMIT=$(git rev-parse HEAD)
REMOTE_COMMIT=$(git rev-parse origin/master)
if [ "$HEAD_COMMIT" != "$REMOTE_COMMIT" ]; then
  echo "✗ Local master is not identical to origin/master. Push the source first."
  exit 1
fi

TAG="v$VERSION"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "✗ GitHub release $TAG already exists."
  exit 1
fi
if git rev-parse -q --verify "$TAG^{commit}" >/dev/null; then
  TAG_COMMIT=$(git rev-parse "$TAG^{commit}")
  if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
    echo "✗ Existing tag $TAG points to another commit."
    exit 1
  fi
  CREATE_TAG=0
else
  CREATE_TAG=1
fi

./package-release.sh

ZIP="dist/Sofa-$VERSION-universal-mac.zip"
DMG="dist/Sofa-$VERSION.dmg"

echo "▸ Verifying release artifacts…"
VERIFY_DIR=$(/usr/bin/mktemp -d "/private/tmp/sofa-release-$VERSION.XXXXXX")
cleanup() { /bin/rm -rf "$VERIFY_DIR"; }
trap cleanup EXIT
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_DIR/unpacked"
APP="$VERIFY_DIR/unpacked/Sofa.app"
[ -d "$APP" ] || { echo "✗ The updater ZIP does not contain Sofa.app."; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || {
  echo "✗ The packaged app has the wrong short version."; exit 1;
}
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$VERSION" ] || {
  echo "✗ The packaged app has the wrong build version."; exit 1;
}
/usr/bin/lipo "$APP/Contents/MacOS/Sofa" -verify_arch arm64
/usr/bin/lipo "$APP/Contents/MacOS/Sofa" -verify_arch x86_64
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/hdiutil verify "$DMG" >/dev/null
/usr/bin/shasum -a 256 "$ZIP" "$DMG"

if [ "$CREATE_TAG" -eq 1 ]; then
  git tag -a "$TAG" -m "Sofa $VERSION" "$HEAD_COMMIT"
fi
git push origin "refs/tags/$TAG"
REMOTE_TAG=$(git ls-remote origin "refs/tags/$TAG^{}" | /usr/bin/awk '{print $1}')
if [ "$REMOTE_TAG" != "$HEAD_COMMIT" ]; then
  echo "✗ The remote tag does not resolve to the source commit."
  exit 1
fi

echo "▸ Uploading a draft release to ${REPO}…"
gh release create "$TAG" "$ZIP" "$DMG" \
  --repo "$REPO" \
  --verify-tag \
  --draft \
  --title "Sofa $VERSION" \
  --notes "${NOTES:-Sofa $VERSION}"

echo "▸ Verifying the uploaded files byte for byte…"
mkdir -p "$VERIFY_DIR/downloaded"
gh release download "$TAG" --repo "$REPO" --dir "$VERIFY_DIR/downloaded"
/usr/bin/cmp "$ZIP" "$VERIFY_DIR/downloaded/$(basename "$ZIP")"
/usr/bin/cmp "$DMG" "$VERIFY_DIR/downloaded/$(basename "$DMG")"

# Only a non-draft release can become /releases/latest, so the updater cannot
# see partially uploaded or unverified files.
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
echo "✓ Published verified Sofa $VERSION. Check for Updates… can now offer it."
