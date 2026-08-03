import AppKit
import Foundation

/// The two escape hatches for "macOS won't stop asking" and "just get this off
/// my Mac". Both exist because Sofa's hardest support cases are not bugs in
/// Sofa at all — they are permission records macOS recorded against an older
/// copy or signature and now quietly refuses to match. Until now the only cure
/// was a paragraph of instructions telling a friend to hunt through System
/// Settings; `tccutil` does the same job in one click, and needs no password.
@MainActor
enum Maintenance {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.pablo.sofa.native"

    // MARK: - Reset permissions

    /// Walks the user out of a stale permission grant.
    ///
    /// IMPORTANT, measured rather than assumed: `tccutil reset` prints
    /// "Successfully reset …" and changes NOTHING for an app's Accessibility or
    /// Automation grant when run without root — verified on this Mac by reading
    /// `AXIsProcessTrusted()` and `AEDeterminePermissionToAutomateTarget` in a
    /// fresh process either side of the call, both of which still answered
    /// "granted". So this must never claim success on the strength of that exit
    /// code. It tries the free path, then takes the user straight to the pane
    /// where the removal actually sticks, which is the − button.
    static func presentResetPermissions() {
        NSApp.activate(ignoringOtherApps: true)

        // Best effort, and genuinely free: on some macOS versions this does
        // clear the record. It is never reported as the fix.
        let attempted = resetPermissions()
        DiagLog.log("maintenance: tccutil reset attempted → \(attempted)")

        let alert = NSAlert()
        alert.messageText = "Make macOS ask for permission again"
        var info = """
            macOS won't let an app revoke its own permissions, so this takes one \
            click from you — but only one, and no password.

            In the window that opens, select Sofa in the list, press the − \
            button to remove it, then add Sofa back and turn it on. That forces \
            macOS to record a fresh grant for the copy you are actually running, \
            which is what a repeated permission request means it lost.

            Theater needs Accessibility. Controlling your browser or player needs \
            Automation.
            """
        if let advice = DiagnosticReport.copyAdvice() {
            let listing = advice.delete.map { "• \($0.path)" }.joined(separator: "\n")
            info += """


                This is very likely your problem: this Mac has more than one copy \
                of Sofa, and the permission belongs to a copy you are not \
                running. Keep \(advice.keep.path) and delete:
                \(listing)
                """
        }
        if AppLocation.isRunningFromQuarantinedLocation {
            info += """


                This is your problem: Sofa is running from the Downloads folder \
                or straight from the disk image, and macOS refuses to keep \
                permissions for an app there. Move Sofa to your Applications \
                folder and open it from there.
                """
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Automation Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: WindowArranger.openAccessibilitySettings()
        case .alertSecondButtonReturn: openAutomationSettings()
        default: break
        }
    }

    private static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        if let url { NSWorkspace.shared.open(url) }
    }

    /// Runs `tccutil reset` for each service Sofa can ask for. Best effort only
    /// — see the note on `presentResetPermissions`: a zero exit status here does
    /// NOT mean the grant was cleared.
    @discardableResult
    static func resetPermissions() -> Bool {
        if runTCCUtil(["reset", "All", bundleID]) { return true }
        var anySucceeded = false
        for service in ["AppleEvents", "Accessibility", "ListenEvent", "Microphone", "ScreenCapture"] {
            if runTCCUtil(["reset", service, bundleID]) { anySucceeded = true }
        }
        return anySucceeded
    }

    private static func runTCCUtil(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Uninstall

    /// Removes Sofa and everything it has written, for when a Mac is in a state
    /// nobody wants to debug over a message thread. The bundle goes to the
    /// Trash rather than being deleted outright — an uninstall triggered by
    /// frustration should still be recoverable.
    static func presentUninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove Sofa from this Mac?"
        alert.informativeText = """
            Sofa moves itself to the Trash and clears what it has stored on this \
            Mac: its permissions, your display name and settings, its saved \
            friends identity, and its logs.

            Your friends list lives with that identity, so installing Sofa again \
            starts you fresh — friends will need to re-add you. Nothing else on \
            your Mac is touched, and no video or account is affected.

            Sofa quits when it's done.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DiagLog.log("maintenance: uninstalling")
        uninstall()
    }

    /// What `uninstall()` would remove, without removing it — so the list can be
    /// checked against a real Mac before anyone trusts the button.
    /// `SOFA_UNINSTALL_DRYRUN=1 <binary>` prints it.
    static func uninstallPlan() -> [String] {
        var plan: [String] = []
        plan.append("login item: \(LoginItem.shared.enabled ? "registered — would unregister" : "not registered")")
        plan.append("permissions: would ask macOS to forget Sofa's TCC records (best effort)")
        plan.append("keychain: would delete the Friends device credential")
        plan.append("defaults domain: \(bundleID)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        for url in leftoverURLs(home: home) {
            let exists = FileManager.default.fileExists(atPath: url.path)
            plan.append("\(exists ? "would delete" : "absent    ") \(url.path)")
        }
        plan.append("would move to Trash: \(Bundle.main.bundleURL.path)")
        return plan
    }

    private static func leftoverURLs(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
            home.appendingPathComponent("Library/Logs/Sofa"),
            home.appendingPathComponent("Library/Application Support/Sofa"),
            home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState"),
            home.appendingPathComponent("Library/HTTPStorages/\(bundleID)"),
            home.appendingPathComponent("Library/Caches/\(bundleID)"),
        ]
    }

    private static func uninstall() {
        // Order matters: undo the things that could relaunch or re-prompt Sofa
        // before the bundle they point at stops existing.
        if LoginItem.shared.enabled { LoginItem.shared.toggle() }
        resetPermissions()
        SocialService.shared.stop()
        deleteStoredIdentity()

        let home = FileManager.default.homeDirectoryForCurrentUser
        for url in leftoverURLs(home: home) where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        // Defaults are also cached in cfprefsd, so a plain file delete can be
        // written straight back out when Sofa quits.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        let bundle = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([bundle]) { _, error in
            Task { @MainActor in
                if let error {
                    DiagLog.log("maintenance: could not trash the app — \(error.localizedDescription)")
                    // Everything else is already gone; show the app in Finder so
                    // dragging it to the Trash is the only step left.
                    NSWorkspace.shared.activateFileViewerSelecting([bundle])
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// The Friends identity lives in the keychain, not in defaults, so it
    /// survives a plain "drag the app to the Trash" and would silently
    /// re-attach a later reinstall to the old account.
    private static func deleteStoredIdentity() {
        SocialService.deleteStoredIdentityForUninstall()
    }

    // MARK: - Restart

    /// Relaunches Sofa. A TCC decision is read once per process, so a reset only
    /// takes effect in a new one.
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
