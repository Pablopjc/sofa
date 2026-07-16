#!/bin/bash
# Regenerates the two menu bar template icons into ../Resources.
#   trayTemplate      → lone armchair (nobody connected)
#   traySofaTemplate  → 2-seat sofa   (friends connected)
# Both are drawn to the same optical size (14pt glyph inside a 20pt-tall
# canvas) so the swap doesn't jump.
set -euo pipefail
cd "$(dirname "$0")"
OUT="../Resources"

echo "▸ Armchair (custom glyph)…"
rsvg-convert -h 20 tray-armchair.svg -o "$OUT/trayTemplate.png"
rsvg-convert -h 40 tray-armchair.svg -o "$OUT/trayTemplate@2x.png"

echo "▸ Sofa (SF Symbols sofa.fill)…"
# Rendered oversized then scaled down with sips: lockFocus honours the display's
# backing scale, so asking for 27x20 directly yields 54x40 on a Retina Mac and
# 27x20 on a non-Retina one. Drawing big and downscaling is size-deterministic.
osascript -l JavaScript - "$OUT" << 'EOF'
ObjC.import('AppKit');

function render(canvasW, canvasH, glyphH, path) {
  const base = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription('sofa.fill', $());
  // Render large, then scale down into place so the small sizes stay crisp.
  const conf = $.NSImageSymbolConfiguration.configurationWithPointSizeWeightScale(
    200, $.NSFontWeightRegular, 2);
  const sym = base.imageWithSymbolConfiguration(conf);
  const s = sym.size;
  const w = glyphH * (s.width / s.height);

  const canvas = $.NSImage.alloc.initWithSize($.NSMakeSize(canvasW, canvasH));
  canvas.lockFocus;
  $.NSGraphicsContext.currentContext.setImageInterpolation($.NSImageInterpolationHigh);
  sym.drawInRectFromRectOperationFraction(
    $.NSMakeRect((canvasW - w) / 2, (canvasH - glyphH) / 2, w, glyphH),
    $.NSZeroRect, $.NSCompositingOperationSourceOver, 1.0);
  canvas.unlockFocus;

  const rep = $.NSBitmapImageRep.imageRepWithData(canvas.TIFFRepresentation);
  const png = rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
  png.writeToFileAtomically(path, true);
}

function run(argv) {
  // 8x the final 27x20 canvas, same 14/20 glyph-to-canvas ratio.
  render(216, 160, 112, argv[0] + '/traySofaTemplate.png');
  return 'ok';
}
EOF

sips -z 40 54 "$OUT/traySofaTemplate.png" --out "$OUT/traySofaTemplate@2x.png" > /dev/null
sips -z 20 27 "$OUT/traySofaTemplate.png" > /dev/null

echo "✓ Regenerated:"
ls -la "$OUT"/tray*.png | awk '{print "  " $NF}'
