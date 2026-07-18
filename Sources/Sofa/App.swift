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
    static let panelWidth: CGFloat = 380

    private var statusItem: NSStatusItem!
    private var panel: SofaPanel!
    private var hostingView: NSHostingView<ContentView>!
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
        installEditMenu()

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

        // Re-fit the panel whenever the content changes shape (entering a room,
        // switching player, a card appearing). objectWillChange fires *before*
        // the change lands, so measure on the next turn of the run loop.
        AppState.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizePanelToFit() }
            }
            .store(in: &cancellables)
        AppState.shared.builtin.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.resizePanelToFit() }
            }
            .store(in: &cancellables)

        let content = NSHostingView(rootView: ContentView())
        hostingView = content
        panel = SofaPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 400),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllApplications,
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        Publishers.CombineLatest3(
            AppState.shared.$theaterActive,
            AppState.shared.$theaterTransitioning,
            AppState.shared.$browserPageFullscreenReady
        )
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .sink { [weak self] needsFullscreenLevel in
                self?.panel.level = needsFullscreenLevel ? .screenSaver : .statusBar
            }
            .store(in: &cancellables)

        // Liquid Glass panel container (macOS 26+), with the classic popover
        // material as fallback on older systems.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.style = .regular
            // Without clipping, the glass paints past its rounded corners and the
            // window's shadow shows through there as a hard dark rim.
            glass.clipsToBounds = true
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
            forName: .sofaHidePanel, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.panel.orderOut(nil) }
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

    /// An accessory app shows no menu bar, but ⌘X/⌘C/⌘V are still dispatched
    /// through the main menu's key equivalents — with no main menu at all,
    /// pasting into the invite field silently does nothing.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Lone armchair when nobody's around, 2-seat sofa once friends join.
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

    // MARK: - Panel sizing

    /// Measures the SwiftUI content and resizes the panel to match, so the
    /// panel is never taller than what it shows.
    ///
    /// The size is measured with a throwaway hosting view: the real one is
    /// installed in the window, so its own fittingSize just reports back the
    /// window height it was given.
    private func resizePanelToFit() {
        let probe = NSHostingView(rootView: ContentView())
        probe.layoutSubtreeIfNeeded()
        let ideal = probe.fittingSize.height
        guard ideal > 100 else { return } // sanity: never collapse the panel

        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 24
        let height = min(ideal, maxHeight)
        guard abs(panel.frame.height - height) > 0.5 else { return }

        // Keep the top edge pinned: the panel hangs from the menu bar.
        var frame = panel.frame
        let topEdge = frame.maxY
        frame.size = NSSize(width: Self.panelWidth, height: height)
        frame.origin.y = topEdge - height
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
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
        AppState.shared.refreshTheaterAvailability()
        resizePanelToFit()
        positionPanel()
        // The viewer must open Sofa after pressing F, before Theater is active.
        // Raise the panel whenever that page fullscreen is detected, and keep it
        // raised through entrance/exit. Normal use stays at status-bar level.
        panel.level = AppState.shared.theaterActive || AppState.shared.theaterTransitioning
            || AppState.shared.browserPageFullscreenReady
            ? .screenSaver
            : .statusBar
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
        // Pass the raw link through: join() parses out address and room code.
        guard AppState.parseTarget(urlString) != nil else { return }

        if panel == nil {
            pendingJoin = urlString // app still launching
            return
        }
        showPanel()
        let state = AppState.shared
        if state.inRoom || state.hosting || state.joining {
            state.showToast("Finish or leave the current party before opening another invite.")
        } else {
            state.joinAddress = urlString
            state.join(target: urlString)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerBridge.shared.stop()
        AppState.shared.stopCallAudio()
        let restoredTheater = AppState.shared.prepareTheaterForTermination()
        AppState.shared.sync.stop()
        // The browser Space transition owns the animation, but the saved frame
        // retries are on our main queue. Briefly drain it before the process
        // exits so Safari/Chrome return exactly where the user left them.
        if restoredTheater {
            RunLoop.current.run(until: Date().addingTimeInterval(2.0))
        }
    }
}
