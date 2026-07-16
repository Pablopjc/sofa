import AppKit

// Generates the two menu bar template icons so that their *ink* — the drawn
// pixels, ignoring any transparent margin — is exactly the same height.
//
// This matters because the two glyphs come from different places: the armchair
// is our own SVG (no margin) while the sofa is SF Symbols' `sofa.fill`, which
// bakes in ~17% padding. Rendering both to the same canvas height therefore
// made the armchair look oversized and the sofa undersized.

let inkHeightPt = 16   // matches the system's own menu bar glyphs

guard CommandLine.arguments.count > 2 else {
    print("usage: maketray.swift <armchair-png-hires> <out-dir>")
    exit(1)
}
let armchairSource = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

/// Bounding box of the non-transparent pixels, in top-left coordinates.
func inkRect(_ rep: NSBitmapImageRep) -> NSRect? {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0, maxY >= 0 else { return nil }
    return NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func bitmap(of image: NSImage) -> NSBitmapImageRep? {
    guard let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

/// Crops to the ink and scales so the ink ends up `inkHeight` pixels tall.
func writeTight(_ image: NSImage, inkHeight: Int, to path: String) -> String {
    guard let src = bitmap(of: image), let ink = inkRect(src) else { return "no ink" }
    let scale = CGFloat(inkHeight) / ink.height
    let outW = max(1, Int((ink.width * scale).rounded()))
    let outH = inkHeight

    guard let dest = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return "no bitmap" }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: dest)
    NSGraphicsContext.current?.imageInterpolation = .high
    // colorAt() is top-left based; drawing is bottom-left based, so flip Y.
    let from = NSRect(x: ink.minX,
                      y: CGFloat(src.pixelsHigh) - ink.maxY,
                      width: ink.width, height: ink.height)
    src.draw(in: NSRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)),
             from: from, operation: .sourceOver, fraction: 1,
             respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()

    guard let png = dest.representation(using: .png, properties: [:]) else { return "no png" }
    try? png.write(to: URL(fileURLWithPath: path))
    return "\(outW)x\(outH)"
}

// Armchair: our own SVG, pre-rendered large by rsvg-convert.
guard let armchair = NSImage(contentsOfFile: armchairSource) else {
    print("couldn't read \(armchairSource)"); exit(1)
}

// Sofa: SF Symbols, asked for at a large point size so downscaling stays crisp.
guard let symbol = NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: "Sofa"),
      let sofa = symbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 300, weight: .regular)) else {
    print("couldn't load sofa.fill"); exit(1)
}

print("  armchair 1x: " + writeTight(armchair, inkHeight: inkHeightPt, to: outDir + "/trayTemplate.png"))
print("  armchair 2x: " + writeTight(armchair, inkHeight: inkHeightPt * 2, to: outDir + "/trayTemplate@2x.png"))
print("  sofa 1x:     " + writeTight(sofa, inkHeight: inkHeightPt, to: outDir + "/traySofaTemplate.png"))
print("  sofa 2x:     " + writeTight(sofa, inkHeight: inkHeightPt * 2, to: outDir + "/traySofaTemplate@2x.png"))
