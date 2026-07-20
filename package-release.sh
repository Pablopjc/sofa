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

# Notarization needs a real Developer ID signature (self-signed/ad-hoc builds
# can't be submitted to Apple). Skip quietly for local/dev builds without one —
# release.sh's own verification step is what actually gates a published release.
#
# The codesign output is captured into a variable before grepping it, not
# piped straight in: under `pipefail`, `grep -q` closing its input as soon as
# it finds a match sends codesign a SIGPIPE, and pipefail then reports that
# harmless signal as the pipeline's failure — hiding a real match.
SIGN_INFO=$(codesign -dvvv dist/Sofa.app 2>&1 || true)
if echo "$SIGN_INFO" | grep -q "Authority=Developer ID Application"; then
  echo "▸ Submitting to Apple's notary service (this can take a few minutes)…"
  NOTARIZE_ZIP=$(/usr/bin/mktemp "/private/tmp/sofa-notarize-$VERSION.XXXXXX.zip")
  /usr/bin/ditto -c -k --keepParent dist/Sofa.app "$NOTARIZE_ZIP"
  /usr/bin/xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "Sofa" --wait
  /bin/rm -f "$NOTARIZE_ZIP"

  echo "▸ Stapling the notarization ticket…"
  /usr/bin/xcrun stapler staple dist/Sofa.app
else
  echo "▸ No Developer ID signature — skipping notarization (local build)."
fi

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

# Not stapling the DMG itself: Apple's ticket is keyed to what was actually
# submitted (the app), not the DMG built afterwards, so `stapler staple` on
# the DMG fails with "Record not found" — there's nothing to staple it to.
# This isn't a problem: Gatekeeper checks the *app's* own staple (already
# present) the moment a friend copies it out of the DMG and opens it.

echo "✓ $DMG"
echo "✓ $APP_ZIP"
