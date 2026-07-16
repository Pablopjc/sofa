#!/bin/bash
# Builds Sofa.app (native Swift version) into dist/.
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Compiling (release, universal arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1

APP="dist/Sofa.app"
BIN=$(find .build -path "*Products/Release/Sofa" -type f 2>/dev/null | head -1)
[ -n "$BIN" ] && [ -f "$BIN" ] || BIN=".build/apple/Products/Release/Sofa"
[ -f "$BIN" ] || { echo "binary not found"; find .build -name Sofa -type f -maxdepth 5; exit 1; }
lipo -info "$BIN" | sed 's/^/▸ /'

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sofa"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/icon.icns "$APP/Contents/Resources/icon.icns"
cp Resources/demo.mp4 "$APP/Contents/Resources/demo.mp4"
cp Resources/trayTemplate.png Resources/trayTemplate@2x.png "$APP/Contents/Resources/"
cp Resources/traySofaTemplate.png Resources/traySofaTemplate@2x.png "$APP/Contents/Resources/"

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

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - "$APP" > /dev/null 2>&1

echo "✓ Built $APP"
