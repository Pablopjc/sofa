import AppKit
import SwiftUI

/// "+" button that opens the system emoji palette. Picks land in a hidden
/// text field parked offscreen inside the panel; each one is forwarded as a
/// reaction and the field is cleared. Built on AppKit (no SwiftUI @State,
/// whose macro plugin isn't in the command-line toolchain).
struct EmojiPickerButton: NSViewRepresentable {
    let onPick: (String) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: "", target: context.coordinator, action: #selector(Coordinator.open(_:))
        )
        button.image = NSImage(
            systemSymbolName: "plus.circle", accessibilityDescription: "More reactions"
        )
        button.isBordered = false
        button.toolTip = "Pick any emoji"
        context.coordinator.onPick = onPick
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onPick = onPick
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onPick: ((String) -> Void)?
        private let catcher = NSTextField()

        @objc func open(_ sender: NSButton) {
            guard let window = sender.window else { return }
            if catcher.superview == nil {
                catcher.frame = NSRect(x: -200, y: -200, width: 60, height: 22)
                catcher.delegate = self
                window.contentView?.addSubview(catcher)
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(catcher)
            NSApp.orderFrontCharacterPalette(catcher)
        }

        func controlTextDidChange(_ obj: Notification) {
            let text = catcher.stringValue
            guard let emoji = text.last.map(String.init) else { return }
            catcher.stringValue = ""
            onPick?(emoji)
        }
    }
}

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
