import AppKit
import SwiftUI

/// The banner that explains why the picture stopped.
///
/// One view, two hosts. Inside the menu-bar panel it sits in `PlayerCard`; when
/// the panel is not on screen — which is most of the time, and always in
/// Theater — it is drawn by `AdBreakOverlay` in a floating window instead. A
/// `showToast` would not do: toasts live in the panel, last 3.5 s and are one
/// line, and this is an ongoing condition the viewer is staring at a frozen
/// frame wondering about.
struct AdBreakBanner: View {
    let ad: AppState.FriendAdBreak
    /// Floating-window styling (over video) rather than in-panel styling.
    let overlay: Bool

    private var headline: String {
        if ad.lost { return "\(AppState.possessive(ad.name).capitalizedFirst) ad break ended, or they dropped" }
        return "Ad break on \(AppState.possessive(ad.name)) side"
    }

    private var body_: String {
        if ad.lost { return "Press play when you're ready." }
        let waited = Date().timeIntervalSince(ad.startedAt)
        if waited > 180 {
            return "That's longer than a usual ad break — they may already be back."
        }
        if let time = ad.filmTime {
            return "Paused at \(Self.clock(time)) — you'll both pick up when their ads finish."
        }
        return "You'll both pick up when their ads finish."
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sofaAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(overlay ? .white : .primary)
                Text(body_)
                    .font(.system(size: 11))
                    .foregroundStyle(overlay ? Color.white.opacity(0.8) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: overlay ? 14 : 10, style: .continuous)
                .fill(overlay ? Color.black.opacity(0.74) : Color.sofaAmber.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: overlay ? 14 : 10, style: .continuous)
                .strokeBorder(Color.sofaAmber.opacity(overlay ? 0.35 : 0.25), lineWidth: 1)
        )
    }
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

/// Floating banner for when the panel is not on screen.
///
/// Deliberately a clone of `ReactionOverlay`'s window recipe — the same
/// `.screenSaver` level and `.canJoinAllSpaces`/`.fullScreenAuxiliary` behaviour
/// is what lets it draw over a browser's own fullscreen Space, which is the
/// whole point during Theater. Positioned top-centre, because Theater reserves
/// the RIGHT column for the video call and reactions already rise there.
@MainActor
final class AdBreakOverlay {
    static let shared = AdBreakOverlay()

    private var panel: NSPanel?
    private init() {}

    func update(_ ad: AppState.FriendAdBreak?) {
        guard let ad else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel()
        panel.contentView = NSHostingView(rootView:
            AdBreakBanner(ad: ad, overlay: true).frame(width: 380)
        )
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 380, height: 76)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - 46,
            width: size.width,
            height: size.height
        )
        if let panel {
            panel.setFrame(frame, display: false)
            return panel
        }
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Click-through: the escape hatch is pressing play in the video itself,
        // which Sofa detects and treats as "I'd rather keep watching".
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        self.panel = panel
        return panel
    }

    /// True when the menu-bar panel is not showing, so the banner has to be
    /// drawn over the video instead of inside the panel.
    static var panelIsHidden: Bool {
        !NSApp.windows.contains { $0 is SofaPanel && $0.isVisible }
    }
}
