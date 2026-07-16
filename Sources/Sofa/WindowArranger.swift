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
    private static let gap: CGFloat = 8

    /// Puts the player on the left (as large as the space allows) and the call
    /// in a column on the right. Nothing overlaps.
    static func arrange(player: PlayerChoice, callApp: CallApp) throws {
        guard hasAccessibilityPermission else { throw ArrangeError.noPermission }
        guard let screen = NSScreen.main else { throw ArrangeError.noScreen }

        // AX uses top-left origin; NSScreen uses bottom-left. Convert.
        let full = screen.frame
        let visible = screen.visibleFrame
        let top = full.height - visible.maxY          // menu bar height
        let left = visible.minX
        let usableW = visible.width
        let usableH = visible.height

        let videoW = usableW - callWidth - gap
        let videoRect = CGRect(x: left, y: top, width: videoW, height: usableH)

        // Call sits in the right column, vertically centred.
        let callRect = CGRect(
            x: left + usableW - callWidth,
            y: top + (usableH - callHeight) / 2,
            width: callWidth,
            height: callHeight
        )

        guard let playerBundle = player.bundleID,
              let playerWindow = frontWindow(ofBundleID: playerBundle) else {
            throw ArrangeError.noPlayerWindow(player.shortLabel)
        }
        guard let callWindow = frontWindow(ofBundleID: callApp.bundleID) else {
            throw ArrangeError.noCallWindow(callApp.name)
        }

        setFrame(playerWindow, videoRect)
        setFrame(callWindow, callRect)
    }

    // MARK: - Accessibility plumbing

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
