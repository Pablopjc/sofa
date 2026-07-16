#!/bin/bash
# Regenerates the two menu bar template icons into ../Resources.
#   trayTemplate      → lone armchair (nobody connected)
#   traySofaTemplate  → 2-seat sofa   (friends connected)
#
# maketray.swift crops each glyph to its actual ink and scales both to the same
# ink height, so the two read as the same size in the menu bar despite coming
# from different sources (our SVG has no margin; SF Symbols bakes one in).
set -euo pipefail
cd "$(dirname "$0")"
OUT="../Resources"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "▸ Rasterising the armchair SVG…"
rsvg-convert -h 400 tray-armchair.svg -o "$TMP/armchair.png"

echo "▸ Cropping both to their ink and matching sizes…"
swift maketray.swift "$TMP/armchair.png" "$OUT"

echo "✓ Regenerated:"
ls -la "$OUT"/tray*.png | awk '{print "  " $NF}'
