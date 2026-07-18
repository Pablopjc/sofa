#!/bin/bash
# Builds the universal app plus the two release artifacts:
# - DMG: the one file to send to a friend
# - ZIP: consumed by Sofa's in-app updater
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP_ZIP="dist/Sofa-$VERSION-universal-mac.zip"
DMG="dist/Sofa-$VERSION.dmg"

./build.sh

echo "▸ Packaging updater archive…"
/bin/rm -f "$APP_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent dist/Sofa.app "$APP_ZIP"

echo "▸ Creating friend installer…"
STAGING=$(/usr/bin/mktemp -d "/private/tmp/sofa-dmg-$VERSION.XXXXXX")
cleanup() { /bin/rm -rf "$STAGING"; }
trap cleanup EXIT
/usr/bin/ditto dist/Sofa.app "$STAGING/Sofa.app"
/bin/ln -s /Applications "$STAGING/Applications"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create \
  -volname "Sofa" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

echo "✓ $DMG"
echo "✓ $APP_ZIP"
