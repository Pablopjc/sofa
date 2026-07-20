#!/bin/bash
# Builds Sofa.app (native Swift version) into dist/.
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Compiling (release, universal arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1

APP="dist/Sofa.app"
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BIN="$BIN_DIR/Sofa"
[ -f "$BIN" ] || { echo "binary not found at $BIN"; exit 1; }
lipo -info "$BIN" | sed 's/^/▸ /'

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sofa"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/icon.icns "$APP/Contents/Resources/icon.icns"
cp Resources/demo.mp4 "$APP/Contents/Resources/demo.mp4"
cp Resources/trayTemplate.png Resources/trayTemplate@2x.png "$APP/Contents/Resources/"
cp Resources/traySofaTemplate.png Resources/traySofaTemplate@2x.png "$APP/Contents/Resources/"
cp -R BrowserExtension "$APP/Contents/Resources/BrowserExtension"

# Keep an unpacked copy beside the app for Chrome's Developer Mode -> Load
# unpacked flow. Safari uses the identical helper through Sofa's built-in bridge.
EXTENSION="dist/Sofa-Theater-Extension"
rm -rf "$EXTENSION"
cp -R BrowserExtension "$EXTENSION"

# Adaptive light/dark icon (macOS 26+) — compiled from the Icon Composer bundle.
ACTOOL=""
for c in /Applications/Xcode.app /Applications/Xcode-beta.app; do
  [ -x "$c/Contents/Developer/usr/bin/actool" ] && ACTOOL="$c/Contents/Developer/usr/bin/actool"
done
if [ -n "$ACTOOL" ]; then
  TMP=$(mktemp -d)
  cp -R Resources/AppIcon.icon "$TMP/Icon.icon"
  "$ACTOOL" "$TMP/Icon.icon" --compile "$TMP" \
    --output-format human-readable-text --notices --warnings \
    --output-partial-info-plist "$TMP/assetcatalog.plist" \
    --app-icon Icon --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 26.0 --platform macosx > /dev/null
  cp "$TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
  rm -rf "$TMP"
  echo "▸ Adaptive light/dark icon included."
else
  # No Xcode 26 actool: strip the asset-catalog icon reference so macOS uses the .icns.
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "▸ Xcode actool not found — classic .icns only."
fi

# Sign with a Developer ID if one is installed — required for notarization,
# which is what skips the Gatekeeper warning for friends. Falls back to the
# stable self-signed identity (permissions survive rebuilds, but no
# notarization) and finally to ad-hoc. See Design/make-signing-cert.sh to
# (re)create the self-signed cert.
#
# SOFA_SIGNING=self-signed forces the legacy identity. Needed exactly once, for
# the 0.1.33 migration bridge: updaters older than 0.1.33 only accept an update
# whose signature is identical to their own, so the release that *teaches* the
# updater to accept Developer ID must itself still carry the old signature.
DEVELOPER_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"' || true)
if [ "${SOFA_SIGNING:-auto}" = "self-signed" ]; then
  DEVELOPER_ID=""
fi

if [ -n "$DEVELOPER_ID" ]; then
  echo "▸ Signing with Developer ID ($DEVELOPER_ID), hardened runtime…"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Sofa.entitlements \
    --sign "$DEVELOPER_ID" "$APP" > /dev/null
elif security find-identity -p codesigning 2>/dev/null | grep -q "Sofa Self-Signed"; then
  echo "▸ Signing with stable identity (Sofa Self-Signed — not notarizable)…"
  codesign --force --deep --sign "Sofa Self-Signed" "$APP" > /dev/null 2>&1
else
  echo "▸ Signing (ad-hoc — run Design/make-signing-cert.sh for stable permissions)…"
  codesign --force --sign - "$APP" > /dev/null 2>&1
fi

echo "✓ Built $APP"
