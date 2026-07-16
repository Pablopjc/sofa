#!/bin/bash
# Publishes a new Sofa version to GitHub Releases, which is where the app's
# "Check for Updates…" looks. Usage: ./release.sh 2.1.0 "What changed"
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

REPO=$(/usr/libexec/PlistBuddy -c "Print :SofaUpdateRepo" Info.plist 2>/dev/null || echo "")
if [ -z "$REPO" ] || [[ "$REPO" == *OWNER* ]]; then
  echo "✗ Set SofaUpdateRepo in Info.plist to your \"user/repo\" first."
  exit 1
fi

echo "▸ Bumping version to $VERSION…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist

./build.sh

ZIP="Sofa-$VERSION-universal-mac.zip"
echo "▸ Packaging $ZIP…"
rm -f "dist/$ZIP"
(cd dist && ditto -c -k --keepParent Sofa.app "$ZIP")

echo "▸ Committing version bump…"
git add -A
git commit -m "Release $VERSION" || echo "  (nothing to commit)"
git push || true

echo "▸ Creating GitHub release v$VERSION on $REPO…"
gh release create "v$VERSION" "dist/$ZIP" \
  --repo "$REPO" \
  --title "Sofa $VERSION" \
  --notes "${NOTES:-Sofa $VERSION}"

echo "✓ Published. Everyone's Check for Updates… will now offer $VERSION."
