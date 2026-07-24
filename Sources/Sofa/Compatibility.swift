import AppKit
import SwiftUI

// MARK: - macOS 12 (Monterey) baseline
//
// Sofa deploys to macOS 12.0 so friends on Macs that can't move past Monterey
// (the 2015–2016 models) can still join a party. The engine — SyncEngine,
// PlayerBridge, WindowArranger, Updater — is already Monterey-clean; only the
// SwiftUI garnish reached past it. Every one of those reaches is funnelled
// through this file, so there is exactly one place to revisit when the floor
// rises again.
//
// Deliberately NOT back-ported (they degrade on their own):
//   • CallAudioVolume — Core Audio process taps need 14.2, already gated, so
//     the call-volume slider simply doesn't appear on Monterey.
//   • NSGlassEffectView — Liquid Glass needs 26, already falls back to
//     NSVisualEffectView.
//
// Build note: the Command Line Tools ship libswiftCompatibility56.a for arm64
// only, so linking the x86_64 slice against a pre-13 target fails there. Build
// with Xcode's toolchain (build.sh handles this) or Intel Macs get no binary.

// MARK: - Concurrency

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(for:)` and `Duration` need macOS 13. Seconds-based sleep
    /// that works all the way back to Monterey.
    static func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - Branding

enum SofaGlyph {
    /// `sofa.fill` arrived with SF Symbols 4 (macOS 13). On Monterey
    /// `Image(systemName:)` would silently draw nothing, leaving a hole beside
    /// the wordmark and on the idle screen — so resolve the symbol at runtime
    /// and fall back to Sofa's own bundled armchair artwork, which stays on
    /// brand. Detected rather than version-gated: the question that matters is
    /// "does this glyph exist here", not "which macOS is this".
    static let systemSymbolAvailable: Bool =
        NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: "Sofa") != nil

    /// The bundled menu-bar artwork, as a template so it tints like a symbol.
    static let bundledMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "traySofaTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        if let retinaURL = Bundle.main.url(forResource: "traySofaTemplate@2x", withExtension: "png"),
           let retina = NSImageRep(contentsOf: retinaURL) {
            retina.size = image.size
            image.addRepresentation(retina)
        }
        image.isTemplate = true
        return image
    }()
}

extension View {
    /// Applies to the fallback image only — the symbol path keeps font sizing.
    @ViewBuilder fileprivate func sofaGlyphSized(_ pointSize: CGFloat) -> some View {
        frame(width: pointSize, height: pointSize)
    }
}

/// Sofa's mark at a given point size, drawn as an SF Symbol where that symbol
/// exists and as the bundled artwork where it does not.
struct SofaMark: View {
    var pointSize: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if SofaGlyph.systemSymbolAvailable {
            Image(systemName: "sofa.fill")
                .font(.system(size: pointSize, weight: weight))
        } else if let mark = SofaGlyph.bundledMark {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .sofaGlyphSized(pointSize)
        } else {
            // Last resort: a shape that exists everywhere, never a blank hole.
            Image(systemName: "tv.fill")
                .font(.system(size: pointSize, weight: weight))
        }
    }
}

// MARK: - Feature availability

enum SofaFeature {
    /// Lowering only the FaceTime call needs a Core Audio process tap, which
    /// arrived in macOS 14.2. The slider must be HIDDEN below that, not merely
    /// inert: showing a live control that snaps back with an error is worse
    /// than not offering it.
    static var callVolumeControl: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }
}

// MARK: - SwiftUI

extension Color {
    /// `Color.gradient` needs macOS 13. Apple's version is an OPAQUE luminance
    /// ramp — lighter at the top, base colour at the bottom. The fallback must
    /// lighten too, not fade: ramping opacity instead would let the panel show
    /// through a filled avatar and, on a dark background, invert the highlight
    /// so the top read darker than the base.
    var sofaGradient: AnyShapeStyle {
        if #available(macOS 13.0, *) {
            return AnyShapeStyle(gradient)
        }
        let base = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let lightened = base.blended(withFraction: 0.18, of: .white) ?? base
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color(nsColor: lightened), self],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

extension View {
    /// Breathing pulse on an SF Symbol — `symbolEffect` needs macOS 14, so
    /// Monterey shows the same glyph, just still.
    @ViewBuilder func sofaPulse() -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.pulse)
        } else {
            self
        }
    }

    /// Cross-fade one SF Symbol into another (Copy → Copied). Needs macOS 14;
    /// on Monterey the surrounding `.animation` still fades the swap, it just
    /// isn't the symbol-aware transition.
    @ViewBuilder func sofaSymbolReplace() -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.symbolEffect(.replace))
        } else {
            self
        }
    }

    /// `onChange(of:initial:_:)` is macOS 14; the single-argument closure it
    /// replaced goes back to macOS 11. Same semantics either way: fire with the
    /// new value, never on first appearance.
    @ViewBuilder func sofaOnChange<V: Equatable>(
        of value: V, perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value) { newValue in action(newValue) }
        }
    }
}

// MARK: - AppKit

extension NSWindow.CollectionBehavior {
    /// Sofa's floating panels (the menu-bar panel and the simulated-call
    /// window) must stay visible across Spaces and over a fullscreen movie.
    ///
    /// `.canJoinAllApplications` — which keeps the panel up regardless of which
    /// app is frontmost — arrived in macOS 13. On Monterey the panel still
    /// rides along via `.canJoinAllSpaces` + `.fullScreenAuxiliary`; it just
    /// hides when another app takes over, which is ordinary panel behaviour.
    static var sofaFloatingPanel: NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        if #available(macOS 13.0, *) {
            behavior.insert(.canJoinAllApplications)
        }
        return behavior
    }
}
