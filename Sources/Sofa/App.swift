import AppKit
import Combine
import SwiftUI

// MARK: - Panel

/// Borderless menu-bar panel that can take keyboard focus (for the join field).
final class SofaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: SofaPanel!
    private var pendingJoin: String?
    private var cancellables = Set<AnyCancellable>()

    // sofa:// links (modern AppKit delegate API — AppKit wires up the Apple
    // Event handler itself; registering one manually gets overwritten).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        handleInvite(urlString: url.absoluteString)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar app: no Dock icon

        // Variable length: the "friends connected" sofa is wider than the
        // lone armchair, so the item grows when someone joins.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
        }
        // Swap armchair ⇄ sofa as friends come and go, so you can tell at a
        // glance from the menu bar whether anyone is in the room.
        // (@Published fires immediately, which sets the initial armchair.)
        AppState.shared.$peerCount
            .map { $0 > 1 } // the relay counts us too
            .removeDuplicates()
            .sink { [weak self] friendsConnected in
                self?.updateTrayIcon(friendsConnected: friendsConnected)
            }
            .store(in: &cancellables)

        let content = NSHostingView(rootView: ContentView())
        panel = SofaPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Liquid Glass panel container (macOS 26+), with the classic popover
        // material as fallback on older systems.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = content
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            content.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: effect.topAnchor),
                content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            ])
            panel.contentView = effect
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            // Behave like a popover: hide on blur unless media is loaded/playing.
            DispatchQueue.main.async {
                if !AppState.shared.mediaActive {
                    self.panel.orderOut(nil)
                }
            }
        }

        if let host = pendingJoin {
            pendingJoin = nil
            showPanel()
            AppState.shared.join(target: host)
        }
    }

    /// Lone armchair when nobody's around, 3-seater sofa once friends join.
    private func updateTrayIcon(friendsConnected: Bool) {
        let name = friendsConnected ? "traySofaTemplate" : "trayTemplate"
        statusItem.button?.image = Self.trayIcon(named: name)
        statusItem.button?.toolTip = friendsConnected
            ? "Sofa — friends connected"
            : "Sofa — watch together"
    }

    /// Sofa's custom glyphs, as template images so macOS tints them like the
    /// system's own menu bar icons.
    private static func trayIcon(named base: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: base, withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            let fallback = NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: "Sofa")
            fallback?.isTemplate = true
            return fallback
        }
        if let retinaURL = Bundle.main.url(forResource: "\(base)@2x", withExtension: "png"),
           let retina = NSImageRep(contentsOf: retinaURL) {
            retina.size = img.size
            img.addRepresentation(retina)
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Panel toggling

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }

        let size = panel.frame.size
        var x = buttonFrame.midX - size.width / 2
        let y = buttonFrame.minY - 6 - size.height
        let minX = screen.visibleFrame.minX + 8
        let maxX = screen.visibleFrame.maxX - size.width - 8
        x = max(minX, min(x, maxX))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - sofa:// links

    private func handleInvite(urlString: String) {
        let host = AppState.parseTarget(urlString)
        guard !host.isEmpty else { return }

        if panel == nil {
            pendingJoin = host // app still launching
            return
        }
        showPanel()
        let state = AppState.shared
        if state.inRoom {
            state.showToast("Already in a party — leave it first to join another.")
        } else {
            state.joinAddress = host
            state.join(target: host)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.sync.stop()
        PlayerBridge.shared.stop()
    }
}

