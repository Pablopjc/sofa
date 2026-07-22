import AppKit
import ApplicationServices
import SwiftUI

/// Pre-flight of every macOS permission Sofa's sync needs, so friends discover
/// missing ones here — with a direct path to the right Settings pane — instead
/// of as a mysterious failure in the middle of a movie.
@MainActor
final class SetupCheck: ObservableObject {
    static let shared = SetupCheck()

    enum Status: Equatable {
        case checking
        case ok
        case denied
        case notAsked
        case info(String)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        var status: Status
        /// Deep link into System Settings, when one exists.
        var settingsAnchor: String?
        /// Bundle id to (re-)ask Automation consent for, when applicable.
        var automationBundleID: String?
        /// Shows a "Show in Finder" button instead of "Open Settings".
        var revealApp: Bool = false
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var running = false

    private init() {}

    private static let automationTargets: [(bundleID: String, name: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.QuickTimePlayerX", "QuickTime Player"),
        ("com.apple.TV", "Apple TV"),
        ("org.videolan.vlc", "VLC"),
    ]

    func run() {
        guard !running else { return }
        running = true

        var next: [Row] = []
        // If Sofa is running translocated / from Downloads / the disk image, no
        // permission below can ever stick. Surface that first, above everything.
        if AppLocation.isRunningFromQuarantinedLocation {
            next.append(Row(
                id: "install-location",
                title: "Move Sofa to Applications first",
                detail: "Sofa is running from Downloads or its disk image. From there macOS forgets every permission each time you open it — so Accessibility keeps switching itself off. Drag Sofa into your Applications folder, reopen it, and then grant the permissions below.",
                status: .denied,
                settingsAnchor: nil,
                revealApp: true
            ))
        }
        for target in Self.automationTargets {
            // Only surface apps that exist on this Mac.
            guard NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: target.bundleID
            ) != nil else { continue }
            next.append(Row(
                id: "automation.\(target.bundleID)",
                title: "Control \(target.name)",
                detail: "Automation permission — this is how Sofa presses play and pause for you.",
                status: .checking,
                settingsAnchor: "Privacy_Automation",
                automationBundleID: target.bundleID
            ))
        }
        next.append(Row(
            id: "accessibility",
            title: "Arrange windows (Theater)",
            detail: "Accessibility permission — lets Theater place the video and your call side by side. If you turned it on and it still shows off here, remove Sofa from the list with the – button and add it back (an older version can leave a stale entry).",
            status: .checking,
            settingsAnchor: "Privacy_Accessibility"
        ))
        next.append(Row(
            id: "browser-js",
            title: "Browser video (YouTube, Netflix…)",
            detail: "One-time browser setting: Safari — Develop menu → Allow JavaScript from Apple Events. Chrome — View → Developer → Allow JavaScript from Apple Events.",
            status: .info("Checked automatically during a party"),
            settingsAnchor: nil
        ))
        rows = next

        // AEDeterminePermissionToAutomateTarget can block, so resolve off-main.
        let targets = next.compactMap { row in
            row.automationBundleID.map { (rowID: row.id, bundleID: $0) }
        }
        Task.detached(priority: .userInitiated) {
            var collected: [String: Status] = [:]
            for target in targets {
                collected[target.rowID] = Self.automationStatus(bundleID: target.bundleID, ask: false)
            }
            let results = collected
            let accessibility: Status = AXIsProcessTrusted() ? .ok : .denied
            await MainActor.run {
                let check = SetupCheck.shared
                for (rowID, status) in results {
                    if let index = check.rows.firstIndex(where: { $0.id == rowID }) {
                        check.rows[index].status = status
                    }
                }
                if let index = check.rows.firstIndex(where: { $0.id == "accessibility" }) {
                    check.rows[index].status = accessibility
                }
                check.running = false
            }
        }
    }

    /// Triggers the system consent prompt for one Automation target.
    func askAutomation(bundleID: String) {
        Task.detached(priority: .userInitiated) {
            _ = Self.automationStatus(bundleID: bundleID, ask: true)
            await MainActor.run {
                SetupCheck.shared.running = false
                SetupCheck.shared.run()
            }
        }
    }

    func openSettings(anchor: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let settingsURL = URL(string: url) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private nonisolated static func automationStatus(bundleID: String, ask: Bool) -> Status {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            descriptor.aeDesc, typeWildCard, typeWildCard, ask
        )
        switch Int(status) {
        case 0:
            return .ok
        case -1743: // errAEEventNotPermitted
            return .denied
        case -1744: // errAEEventWouldRequireUserConsent
            return .notAsked
        case -600: // procNotFound — the app isn't running, macOS can't say yet
            return .info("Open the app once, then check again")
        default:
            return .info("Could not check (error \(status))")
        }
    }
}

// MARK: - View

struct SetupCheckView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var check = SetupCheck.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Setup Check")
                .font(.system(size: 24, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Text("Everything Sofa needs to sync your movie nights.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(check.rows) { row in
                    SetupCheckRow(row: row)
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 10) {
                Button {
                    check.run()
                } label: {
                    Text("Check Again").font(.system(size: 12, weight: .medium))
                }
                .sofaGlassButton()
                .disabled(check.running)

                Button {
                    state.showingSetupCheck = false
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .sofaProminentButton()
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 22).padding(.bottom, 16)
        .onAppear { check.run() }
    }
}

private struct SetupCheckRow: View {
    let row: SetupCheck.Row

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(detailText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            actionButton
        }
    }

    private var detailText: String {
        if case .info(let note) = row.status { return note }
        return row.detail
    }

    @ViewBuilder private var statusIcon: some View {
        switch row.status {
        case .checking:
            ProgressView().controlSize(.small)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.red)
        case .notAsked:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
        case .info:
            Image(systemName: "info.circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch row.status {
        case .denied:
            if row.revealApp {
                Button("Show in Finder") { AppLocation.revealInFinder() }
                    .sofaGlassButton()
                    .font(.system(size: 11))
                    .fixedSize()
            } else if let anchor = row.settingsAnchor {
                Button("Open Settings") { SetupCheck.shared.openSettings(anchor: anchor) }
                    .sofaGlassButton()
                    .font(.system(size: 11))
                    .fixedSize()
            }
        case .notAsked:
            if let bundleID = row.automationBundleID {
                Button("Allow…") { SetupCheck.shared.askAutomation(bundleID: bundleID) }
                    .sofaGlassButton()
                    .font(.system(size: 11))
                    .fixedSize()
            }
        default:
            EmptyView()
        }
    }
}
