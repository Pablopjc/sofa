import AppKit

/// Detects which supported media players are currently running, so the UI can
/// offer them as sources — like Control Center's Now Playing shows active apps.
///
/// Uses NSWorkspace only (no AppleScript), so it is instant and never triggers
/// an automation permission prompt just from opening the panel. Live playback
/// status for the *selected* player still comes from PlayerBridge.
enum MediaSourceDetector {
    @MainActor
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }

    static func runningPlayers(in runningIDs: Set<String>) -> [PlayerChoice] {
        return PlayerChoice.externalPlayers.filter {
            guard let bundleID = $0.bundleID else { return false }
            return runningIDs.contains(bundleID)
        }
    }

    /// Media apps that can't be automated at all (no AppleScript support), so
    /// they can never appear as a source. Detected only to explain why, and
    /// point at a route that does work.
    struct UnsupportedApp {
        let name: String
        let bundleID: String
        let advice: String
    }

    static let knownUnsupported: [UnsupportedApp] = [
        UnsupportedApp(
            name: "Prime Video",
            bundleID: "com.amazon.aiv.AIVApp",
            advice: "The Prime Video app can’t be controlled by other apps. Open primevideo.com in Chrome or Safari instead and Sofa can sync it."
        )
    ]

    static func runningUnsupported(in runningIDs: Set<String>) -> [UnsupportedApp] {
        return knownUnsupported.filter { runningIDs.contains($0.bundleID) }
    }
}
