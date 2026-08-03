import AppKit
import Foundation
import ServiceManagement

/// "Open Sofa at login" — off by default, and the reason invitations can reach
/// someone who never opened the app.
///
/// The relay already queues a party invitation for an offline friend and
/// replays it the moment their Sofa reconnects (see `SocialHub.connectEvents`).
/// What it cannot do is wake a Mac where Sofa isn't running at all: macOS gives
/// a Developer-ID app outside the App Store no reliable way to be launched by a
/// push. So the honest mechanism is the ordinary one — keep Sofa running as the
/// menu-bar agent it already is (`LSUIElement`), and "I didn't have the app
/// open" becomes "I didn't have the *panel* open", which the notification and
/// the invitation card already handle.
///
/// Two implementations, one meaning:
///   • macOS 13+ — `SMAppService.mainApp`, the modern registration that shows up
///     in System Settings → General → Login Items under Sofa's own name.
///   • macOS 12 (Monterey) — a plain LaunchAgent plist in ~/Library/LaunchAgents.
///     launchd loads it at the next login on its own, so nothing has to be
///     spawned here; removing the file undoes it just as completely.
@MainActor
final class LoginItem: ObservableObject {
    static let shared = LoginItem()

    /// Mirrors the real system state, re-read rather than remembered — the user
    /// can turn Sofa off in System Settings without telling the app.
    @Published private(set) var enabled = false

    private let agentLabel = "com.pablo.sofa.native.login"

    private init() {
        refresh()
        // The user can turn Sofa off in System Settings without telling us, so
        // re-read whenever they come back to the app rather than trusting a
        // value cached at launch.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in LoginItem.shared.refresh() }
        }
    }

    /// Re-reads the system's answer. Cheap; call it whenever the menu opens so a
    /// change made in System Settings shows up here.
    func refresh() {
        let value = readEnabled()
        if enabled != value { enabled = value }
    }

    func toggle() {
        setEnabled(!enabled)
    }

    private func setEnabled(_ on: Bool) {
        do {
            if #available(macOS 13.0, *) {
                let service = SMAppService.mainApp
                if on { try service.register() } else { try service.unregister() }
            } else {
                try setLegacyAgent(on)
            }
        } catch {
            // The usual cause is running from the DMG or a translocated copy,
            // where the registered path would be gone by the next login.
            AppState.shared.showToast(
                "Move Sofa to your Applications folder first, then try again."
            )
            refresh()
            return
        }
        refresh()
        AppState.shared.showToast(
            enabled
                ? "Sofa will run in the background — invitations reach you without opening it."
                : "Sofa won’t open at login. Invitations arrive only while it’s running."
        )
    }

    private func readEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return true
            // .requiresApproval means Sofa is registered but the user switched
            // it off in System Settings — the truthful answer here is "no".
            default: return false
            }
        }
        return FileManager.default.fileExists(atPath: legacyAgentURL.path)
    }

    // MARK: - Monterey

    private var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    private func setLegacyAgent(_ on: Bool) throws {
        let url = legacyAgentURL
        guard on else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        // Point at the executable inside the bundle that is running right now,
        // so a copy in ~/Applications or a renamed bundle still works.
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            // Sofa is a menu-bar agent, not a daemon: if the user quits it, it
            // should stay quit until the next login.
            "KeepAlive": false,
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: url, options: .atomic)
    }
}
