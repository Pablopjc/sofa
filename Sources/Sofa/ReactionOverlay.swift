import AppKit

/// Floating emoji reactions, drawn over everything — including the fullscreen
/// video Space — in a transparent, click-through panel. Each reaction drifts
/// up from the bottom-right corner and fades out, iMessage-style.
@MainActor
final class ReactionOverlay {
    static let shared = ReactionOverlay()

    private var panel: NSPanel?
    private var activeCount = 0

    private init() {}

    func show(_ emoji: String) {
        let panel = ensurePanel()
        guard let content = panel.contentView else { return }
        panel.orderFrontRegardless()

        let label = NSTextField(labelWithString: emoji)
        label.font = .systemFont(ofSize: 56)
        label.sizeToFit()
        // Random lane near the right edge so simultaneous reactions don't stack.
        let maxX = max(10, content.bounds.width - label.frame.width - 14)
        let x = maxX - CGFloat.random(in: 0...(content.bounds.width * 0.45))
        label.frame.origin = NSPoint(x: max(10, x), y: -label.frame.height)
        label.alphaValue = 0.95
        label.wantsLayer = true
        content.addSubview(label)
        activeCount += 1

        let travel = content.bounds.height * CGFloat.random(in: 0.35...0.6)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 2.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().frame.origin.y = travel
            label.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                label.removeFromSuperview()
                guard let self else { return }
                self.activeCount -= 1
                // Hide the panel when idle so it never lingers over other apps.
                if self.activeCount <= 0 {
                    self.activeCount = 0
                    self.panel?.orderOut(nil)
                }
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        // Follow the screen where the action is: the one with the key window,
        // falling back to the main screen. Anchored to the raw screen edge
        // (not visibleFrame) so reactions rise from the very bottom, behind
        // the Dock if there is one — like iMessage effects.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let width: CGFloat = 420
        let frame = NSRect(
            x: screen.frame.maxX - width,
            y: screen.frame.minY,
            width: width,
            height: screen.frame.height
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
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        panel.contentView = content
        self.panel = panel
        return panel
    }
}
