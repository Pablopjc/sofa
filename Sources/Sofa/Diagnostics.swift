import AppKit
import UserNotifications

// MARK: - Persistent log

/// Tiny persistent log at ~/Library/Logs/Sofa/Sofa.log, so "it broke yesterday
/// on my friend's Mac" leaves evidence a diagnostic report can carry. Distinct
/// from the dev-only SOFA_TRACE_SYNC firehose: this records *events* (launches,
/// panel shows, theater attempts, permission denials, toasts, hangs) at a rate
/// of a few lines a minute, never the 0.2 s poll loop.
enum DiagLog {
    private static let queue = DispatchQueue(label: "sofa.diaglog", qos: .utility)
    private static let maxBytes = 512 * 1024

    static let logDirectory = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appendingPathComponent("Logs/Sofa", isDirectory: true)
    static let logURL = logDirectory.appendingPathComponent("Sofa.log")

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Safe from any thread; never blocks the caller on I/O.
    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(
                at: logDirectory, withIntermediateDirectories: true
            )
            rotateIfNeeded()
            // O_APPEND, not seek-then-write: the duplicate-copy situation this
            // log exists to diagnose means TWO Sofas may be appending at once,
            // and per-process seeks would overwrite each other's lines. The
            // kernel serializes O_APPEND writes on a local filesystem.
            let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return } // logging must never break the app
            _ = line.withCString { pointer in
                write(fd, pointer, strlen(pointer))
            }
            close(fd)
        }
    }

    /// Blocks until every line enqueued so far is on disk. The writes are
    /// fire-and-forget on a background queue, so without this a line logged
    /// right before exit() — "terminate: clean quit", the whole point of which
    /// is distinguishing quits from crashes — would routinely be discarded.
    /// Call only on quit paths.
    static func flush() {
        queue.sync {}
    }

    /// One old generation is enough history for a report.
    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let bytes = attributes[.size] as? Int, bytes > maxBytes else { return }
        let old = logDirectory.appendingPathComponent("Sofa.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }

    /// Last `maxLines` of the log, read on the log's own queue so a report
    /// never races a write. Reads the rotated generation too: right after a
    /// rotation the live file is nearly empty, and a report generated at that
    /// moment would otherwise carry almost no history.
    static func tail(maxLines: Int) -> String {
        queue.sync {
            let old = (try? String(
                contentsOf: logDirectory.appendingPathComponent("Sofa.log.1"), encoding: .utf8
            )) ?? ""
            let current = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let combined = old + current
            guard !combined.isEmpty else { return "(no log yet)" }
            let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(maxLines).joined(separator: "\n")
        }
    }
}

// MARK: - Main-thread watchdog

/// "The app froze and the icon did nothing" is invisible after the fact unless
/// someone was watching. This pings the main thread once a second from a
/// background timer; when a pong comes back late, the stall's duration lands in
/// the log with a timestamp — which is exactly the correlation a report needs
/// ("the panel didn't open at 21:04" ↔ "main thread stalled 12 s at 21:04").
final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()
    private let lock = NSLock()
    private var lastPong = Date()
    private var stallStart: Date?
    private var asleep = false
    private var checker: DispatchSourceTimer?

    private init() {}

    func start() {
        guard checker == nil else { return }

        // The pong is a Timer in .common modes, NOT DispatchQueue.main.async:
        // modal alerts and menu tracking spin the run loop in modes that
        // starve dispatch blocks but still service common-mode timers. With
        // async pongs, every open NSAlert was logged as a multi-second "hang".
        let pong = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.lastPong = Date()
            let stalledSince = self.stallStart
            self.stallStart = nil
            self.lock.unlock()
            if let since = stalledSince {
                let seconds = Date().timeIntervalSince(since)
                DiagLog.log(String(format: "watchdog: main thread was unresponsive for %.1f s", seconds))
            }
        }
        pong.tolerance = 0.2
        RunLoop.main.add(pong, forMode: .common)

        // Wall-clock keeps advancing through system sleep while both timers
        // stand still, so without these brackets every overnight sleep would
        // wake up as a fabricated eight-hour "hang". (A monotonic clock is NOT
        // the fix: mach time pauses during sleep on Intel but keeps ticking on
        // Apple Silicon.) didWake arrives on the main thread, so resetting the
        // pong there is itself proof of liveness before checking resumes.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.asleep = true
            self.stallStart = nil
            self.lock.unlock()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.lastPong = Date()
            self.stallStart = nil
            self.asleep = false
            self.lock.unlock()
        }

        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sofa.watchdog", qos: .utility))
        source.schedule(deadline: .now() + 1, repeating: 1.0)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if !self.asleep,
               Date().timeIntervalSince(self.lastPong) > 3, self.stallStart == nil {
                self.stallStart = self.lastPong
            }
            self.lock.unlock()
        }
        source.resume()
        checker = source
    }
}

// MARK: - Diagnostic report

/// Gathers everything needed to debug a friend's Mac remotely into one text
/// file on their Desktop: versions, install location, permission states,
/// duplicate copies, relay reachability, app state, and the recent event log.
enum DiagnosticReport {
    /// Every copy of Sofa LaunchServices knows about. More than one is the
    /// classic cause of "the Accessibility switch is on but macOS ignores it":
    /// the switch belongs to the copy the user is NOT running.
    static func installedCopies() -> [URL] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pablo.sofa.native"
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
    }

    /// Which copy to keep and which to delete, phrased so the two can never
    /// contradict each other. "Delete everything except the running copy"
    /// sounds right but is not: run Sofa from Downloads and it would tell the
    /// user to trash the good /Applications install. Keep the /Applications
    /// copy when one exists; only otherwise keep the running one.
    static func copyAdvice() -> (keep: URL, delete: [URL])? {
        let copies = installedCopies()
        guard copies.count > 1 else { return nil }
        let keep = copies.first { $0.path.hasPrefix("/Applications/") }
            ?? Bundle.main.bundleURL
        let delete = copies.filter { $0.path != keep.path }
        guard !delete.isEmpty else { return nil }
        return (keep, delete)
    }

    /// Collects (partly async: relay probe, notification status, codesign) and
    /// writes the report. Completion runs on the main queue with the file URL,
    /// or nil if writing failed. `directory` overrides the Desktop for tests.
    @MainActor
    static func generate(directory: URL? = nil, completion: @escaping (URL?) -> Void) {
        // App state must be read on the main actor; snapshot it first.
        let state = AppState.shared
        let stateSection = """
        [State]
        status: \(state.statusLabel)
        player: \(state.playerChoice.rawValue)
        in room: \(state.inRoom)  hosting: \(state.hosting)  test mode: \(state.isTestMode)
        peers: \(state.peerCount)  friends known: \(state.friends.count)
        relay disconnected: \(state.disconnected)
        extension: \(String(describing: state.extLive))
        theater active: \(state.theaterActive)  transitioning: \(state.theaterTransitioning)
        page fullscreen ready: \(state.canEnterTheater)
        detected sources: \(state.detectedSources.map(\.rawValue).joined(separator: ", "))
        """

        // Read on the main actor; AXIsProcessTrusted answers for the process
        // either way, but the accessor is isolated.
        let axGranted = WindowArranger.hasAccessibilityPermission

        Task.detached(priority: .userInitiated) {
            let report = await assemble(stateSection: stateSection, axGranted: axGranted)
            let dir = directory ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let name = "Sofa Report \(Self.fileStamp.string(from: Date())).txt"
            let url = dir.appendingPathComponent(name)
            let ok = (try? report.write(to: url, atomically: true, encoding: .utf8)) != nil
            DiagLog.log("diagnostics: report \(ok ? "saved to \(url.path)" : "FAILED to write")")
            await MainActor.run { completion(ok ? url : nil) }
        }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    // MARK: Assembly (off-main)

    private static func assemble(stateSection: String, axGranted: Bool) async -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let bundlePath = Bundle.main.bundlePath

        var sections: [String] = []
        sections.append("""
        Sofa Diagnostic Report
        Generated: \(DiagLog.tailHeaderDate())
        Sofa \(version) — send this file to the person helping you debug.
        It includes recent Sofa activity (which may mention friend names and
        video titles) but no passwords, links, or message contents.
        """)

        // — App / install —
        var app: [String] = []
        app.append("path: \(bundlePath)")
        app.append("translocated / not installed: \(AppLocation.isRunningFromQuarantinedLocation)")
        app.append("quarantine attribute: \(hasQuarantineAttribute(path: bundlePath))")
        let copies = installedCopies()
        app.append("copies on this Mac (\(copies.count)):")
        for copy in copies {
            let marker = copy.path == Bundle.main.bundleURL.path ? "  ← running" : ""
            app.append("  \(copy.path)\(marker)")
        }
        if let advice = copyAdvice() {
            app.append("ADVICE: keep \(advice.keep.path), delete "
                + advice.delete.map(\.path).joined(separator: ", "))
        }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        if running.count > 1 {
            app.append("WARNING: \(running.count) instances are running right now")
        }
        app.append("signature:\n\(codesignSummary(path: bundlePath))")
        sections.append("[App]\n" + app.joined(separator: "\n"))

        // — System —
        var sys: [String] = []
        sys.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        sys.append("model: \(sysctlString("hw.model") ?? "?")")
        #if arch(arm64)
        sys.append("architecture: arm64")
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        sys.append("architecture: x86_64\(translated == 1 ? " (Rosetta)" : "")")
        #endif
        sections.append("[System]\n" + sys.joined(separator: "\n"))

        // — Permissions —
        var perms: [String] = []
        perms.append("accessibility (Theater): \(axGranted ? "granted" : "DENIED — see the note below")")
        if !axGranted {
            perms.append("  note: if the switch looks ON in \(SystemUINames.settingsApp), it belongs to")
            perms.append("  another copy or an older version. Remove Sofa from the Accessibility")
            perms.append("  list with the − button, then add it back from /Applications.")
        }
        for target in SetupCheck.automationTargets {
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) != nil
            else { continue }
            let status = SetupCheck.automationStatus(bundleID: target.bundleID, ask: false)
            perms.append("automation → \(target.name): \(describe(status))")
        }
        let notif = await notificationStatus()
        perms.append("notifications: \(notif)")
        sections.append("[Permissions]\n" + perms.joined(separator: "\n"))

        sections.append(stateSection)

        // — Relay —
        sections.append("[Network]\n" + (await relayProbe()))

        // — Recent events —
        sections.append("[Recent log — newest last]\n" + DiagLog.tail(maxLines: 250))

        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func describe(_ status: SetupCheck.Status) -> String {
        switch status {
        case .ok: return "granted"
        case .denied: return "DENIED"
        case .notAsked: return "not asked yet"
        case .checking: return "checking"
        case .info(let text): return text
        }
    }

    private static func hasQuarantineAttribute(path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// codesign -dv on our own bundle: shows the identity the running copy
    /// carries, which is what a stale TCC entry disagrees with.
    private static func codesignSummary(path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // -dvv, not -dv: only the double-verbose form prints the Authority
        // chain, which is what tells a Developer ID build from a self-signed
        // one — the exact mismatch behind stale permission entries.
        process.arguments = ["-dvv", path]
        let pipe = Pipe()
        process.standardError = pipe // codesign -dv prints to stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return "  (codesign unavailable: \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let interesting = ["Identifier=", "TeamIdentifier=", "Authority=", "Signature=", "flags="]
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { line in interesting.contains { line.contains($0) } }
            .map { "  \($0)" }
        return lines.isEmpty ? "  (unsigned or unreadable)" : lines.joined(separator: "\n")
    }

    private static func notificationStatus() async -> String {
        // UNUserNotificationCenter.current() raises an uncatchable Obj-C
        // exception when the process has no bundle proxy (bare SPM binary,
        // tests) — that would kill the entire report, not just this line.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return "unknown (not running from an app bundle)"
        }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let text: String
                switch settings.authorizationStatus {
                case .authorized: text = "granted"
                case .denied: text = "DENIED"
                case .notDetermined: text = "not asked yet"
                case .provisional: text = "provisional"
                default: text = "status \(settings.authorizationStatus.rawValue)"
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// One round-trip to the relay proves DNS + TLS + the Worker being up.
    private static func relayProbe() async -> String {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "SofaRelayURL") as? String,
              let url = URL(string: base) else { return "relay: no URL configured" }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return "relay \(url.host ?? ""): reachable, HTTP \(code), \(ms) ms"
        } catch {
            return "relay \(url.host ?? ""): UNREACHABLE — \(error.localizedDescription)"
        }
    }
}

extension DiagLog {
    /// Human date for the report header, same format as log lines.
    static func tailHeaderDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: Date())
    }
}
