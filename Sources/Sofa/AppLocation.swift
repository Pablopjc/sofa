import AppKit
import Foundation

/// Detects when Sofa is running from a place where macOS will not let its
/// Accessibility / Automation grants persist — the single most common reason a
/// friend "turns Accessibility on, but Theater still won't work, and macOS keeps
/// asking again on every launch and even after a restart".
///
/// When a freshly-downloaded, quarantined app is launched straight from the
/// Downloads folder or the mounted `.dmg`, Gatekeeper runs it *translocated* from
/// a randomized, read-only path. Every launch is therefore a different path, so a
/// permission granted to one launch never applies to the next. Moving the app
/// into /Applications (a Finder drag) strips the quarantine and stops
/// translocation, after which the grant sticks normally.
enum AppLocation {
    /// True when the app is translocated, still on the disk image, or running
    /// from Downloads — i.e. it has not actually been installed. In these
    /// states no TCC permission (Accessibility, Automation) can persist.
    static var isRunningFromQuarantinedLocation: Bool {
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") { return true }        // Gatekeeper path randomization
        if path.hasPrefix("/private/var/folders/") { return true }    // translocated temp path
        if path.hasPrefix("/Volumes/") { return true }                // launched from the .dmg
        if path.range(of: #"^/Users/[^/]+/Downloads/"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Reveals Sofa in Finder so the user can drag it into Applications.
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
