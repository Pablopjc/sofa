import AppKit
import ApplicationServices

/// Lays out the video player and a video-call window side by side so you can
/// watch together *and* see your friend, without the call covering the movie.
///
/// Uses the Accessibility API straight from Swift rather than shelling out to
/// osascript: TCC attributes the permission to the process that asks, so going
/// through osascript would ask the user to grant *osascript* assistive access
/// instead of Sofa.
@MainActor
enum WindowArranger {

    struct CallApp {
        let name: String
        let bundleID: String
    }

    /// Known video-call apps, in the order we'd rather pick them.
    static let knownCallApps: [CallApp] = [
        CallApp(name: "FaceTime", bundleID: "com.apple.FaceTime"),
        CallApp(name: "Zoom", bundleID: "us.zoom.xos"),
        CallApp(name: "Discord", bundleID: "com.hnc.Discord"),
        CallApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
        CallApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams"),
        CallApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp"),
        CallApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        CallApp(name: "Telegram", bundleID: "ru.keepcoder.Telegram"),
        CallApp(name: "Skype", bundleID: "com.skype.skype"),
        CallApp(name: "Webex", bundleID: "Cisco-Systems.Spark"),
    ]

    /// The call app that's running right now, if any.
    static func runningCallApp() -> CallApp? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return knownCallApps.first { running.contains($0.bundleID) }
    }

    // MARK: - Permission

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "grant accessibility access" prompt.
    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Layout

    enum ArrangeError: LocalizedError {
        case noPermission
        case noPlayerWindow(String)
        case noCallWindow(String)
        case noScreen

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Sofa needs Accessibility access to move windows."
            case .noPlayerWindow(let app):
                return "Couldn’t find a \(app) window — is your video open?"
            case .noCallWindow(let app):
                return "Couldn’t find a \(app) window — is your call open?"
            case .noScreen:
                return "Couldn’t read the screen size."
            }
        }
    }

    /// Width reserved on the right for the call, and the gap between windows.
    private static let callWidth: CGFloat = 320
    private static let callHeight: CGFloat = 420
    private static let gap: CGFloat = 12

    /// Who occupies the right-hand column in Theater mode.
    enum CallTarget {
        case app(CallApp)   // a real call app, moved via Accessibility
        case fake           // Sofa's own pretend-FaceTime window (Test Zone)
        case none           // no call: the movie takes the whole stage
    }

    /// Theater mode: a black backdrop covers the whole screen so nothing but
    /// the movie (and the call, if any) is visible — the movie fills everything
    /// left of the call column and the desktop disappears.
    static func enterTheater(player: PlayerChoice, call: CallTarget) throws {
        guard hasAccessibilityPermission else { throw ArrangeError.noPermission }
        guard let screen = NSScreen.main else { throw ArrangeError.noScreen }

        // AX uses top-left origin; NSScreen uses bottom-left. Convert.
        let full = screen.frame
        let visible = screen.visibleFrame
        let top = full.height - visible.maxY          // menu bar height
        let left = visible.minX
        let usableW = visible.width
        let usableH = visible.height

        let hasColumn: Bool
        if case .none = call { hasColumn = false } else { hasColumn = true }

        // Movie: flush to the left edge, full height, up to the call column
        // (or wall to wall when there's no call).
        let videoW = hasColumn ? usableW - callWidth - gap : usableW
        let videoRect = CGRect(x: left, y: top, width: videoW, height: usableH)

        guard let playerBundle = player.bundleID,
              let playerWindow = frontWindow(ofBundleID: playerBundle) else {
            throw ArrangeError.noPlayerWindow(player.shortLabel)
        }
        setFrame(playerWindow, videoRect)

        switch call {
        case .app(let callApp):
            guard let callWindow = frontWindow(ofBundleID: callApp.bundleID) else {
                throw ArrangeError.noCallWindow(callApp.name)
            }
            // Right column, vertically centred, floating on black (AX coords).
            setFrame(callWindow, CGRect(
                x: left + usableW - callWidth,
                y: top + (usableH - callHeight) / 2,
                width: callWidth,
                height: callHeight
            ))
        case .fake:
            // Our own window: native bottom-left coords, no AX needed.
            FakeCall.shared.position(frame: NSRect(
                x: visible.maxX - callWidth,
                y: visible.midY - callHeight / 2,
                width: callWidth,
                height: callHeight
            ))
        case .none:
            break
        }

        // Black out everything else, then lift the stars above the backdrop
        // (activation raises an app's windows within the same level).
        TheaterBackdrop.shared.show(on: screen)
        if let playerApp = NSRunningApplication.runningApplications(withBundleIdentifier: playerBundle).first {
            playerApp.activate()
        }
        if case .app(let callApp) = call,
           let callRunning = NSRunningApplication.runningApplications(withBundleIdentifier: callApp.bundleID).first {
            callRunning.activate()
        }
    }

    static func exitTheater() {
        TheaterBackdrop.shared.hide()
    }

    static var theaterActive: Bool { TheaterBackdrop.shared.isActive }
}

/// The full-screen black curtain behind the movie and the call.
@MainActor
final class TheaterBackdrop {
    static let shared = TheaterBackdrop()
    private var window: NSWindow?

    var isActive: Bool { window != nil }

    func show(on screen: NSScreen) {
        hide()
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.level = .normal
        w.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false

        // A whisper of a hint, bottom-left on the black.
        let hint = NSTextField(labelWithString: "Theater — open Sofa in the menu bar to exit")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.22)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: 20, y: 16)
        w.contentView?.addSubview(hint)

        w.orderFront(nil)
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Accessibility plumbing

@MainActor
extension WindowArranger {
    private static func frontWindow(ofBundleID bundleID: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        // Prefer the main window; some apps only expose the window list.
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &main) == .success,
           let window = main, CFGetTypeID(window) == AXUIElementGetTypeID() {
            return (window as! AXUIElement)
        }
        var list: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
              let windows = list as? [AXUIElement], let first = windows.first
        else { return nil }
        return first
    }

    private static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var position = rect.origin
        var size = rect.size
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        // Some apps clamp the size on the first pass (eg. a minimum width kicks
        // in before the move lands), so set the position again to be sure.
        if let posValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        }
    }
}
