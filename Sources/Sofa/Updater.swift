import AppKit
import Foundation

/// Checks GitHub Releases for a newer build, downloads it, and swaps the app
/// bundle in place.
///
/// Deliberately lightweight instead of Sparkle, but still fail-closed: every
/// archive must be intact, have the requested bundle/version and carry exactly
/// the same designated code-signing requirement as the installed Sofa app.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published var busy = false

    struct Release {
        let version: String
        let notes: String
        let zipURL: URL
    }

    enum UpdaterError: LocalizedError {
        case notConfigured
        case badArchive(String)
        case command(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No update repository is configured."
            case .badArchive(let why): return why
            case .command(let out): return out
            }
        }
    }

    /// "owner/repo", set in Info.plist so it can change without touching code.
    private var repo: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SofaUpdateRepo") as? String,
              value.contains("/"), !value.contains("OWNER") else { return nil }
        return value
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - Check

    func checkForUpdates() {
        guard !busy else { return }
        guard let repo else {
            AppState.shared.showToast("Updates aren’t set up yet — no repository configured.")
            return
        }
        busy = true
        AppState.shared.showToast("Checking for updates…")

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, error in
            Task { @MainActor in
                self.busy = false
                if let error {
                    AppState.shared.showToast("Update check failed: \(error.localizedDescription)")
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 {
                    AppState.shared.showToast("No releases published yet.")
                    return
                }
                guard code == 200, let data, let release = Self.parse(data) else {
                    AppState.shared.showToast("Update check failed (HTTP \(code)).")
                    return
                }
                if Self.isNewer(release.version, than: self.currentVersion) {
                    self.promptToInstall(release)
                } else {
                    AppState.shared.showToast("You’re up to date (\(self.currentVersion)).")
                }
            }
        }.resume()
    }

    /// Parses GitHub's "latest release" JSON, picking the mac .zip asset.
    static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let zips = assets.filter { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.hasSuffix(".zip") && !name.contains("Extension")
                && !name.contains("source")
        }
        // The release also contains the friend-facing DMG and may contain the
        // browser helper. Always choose the complete universal app archive.
        let asset = zips.first {
            ($0["name"] as? String)?.contains("universal-mac") == true
        } ?? zips.first { ($0["name"] as? String)?.contains("mac") == true }
        guard let asset,
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: (obj["body"] as? String) ?? "", zipURL: url)
    }

    /// Numeric comparison so 2.10.0 > 2.9.0 (a plain string compare gets this wrong).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    // MARK: - Prompt

    private func promptToInstall(_ release: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sofa \(release.version) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You have \(currentVersion). Update now?"
            : "You have \(currentVersion).\n\n\(release.notes)"
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            download(release)
        }
    }

    // MARK: - Download & install

    private func download(_ release: Release) {
        busy = true
        AppState.shared.showToast("Downloading Sofa \(release.version)…")

        URLSession.shared.downloadTask(with: release.zipURL) { tempURL, _, error in
            // The temp file is deleted as soon as this handler returns, so move
            // it somewhere durable *before* hopping to the main actor.
            var moved: URL?
            if let tempURL {
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sofa-update-\(UUID().uuidString).zip")
                try? FileManager.default.moveItem(at: tempURL, to: dest)
                moved = dest
            }
            Task { @MainActor in
                self.busy = false
                guard let moved else {
                    AppState.shared.showToast("Download failed: \(error?.localizedDescription ?? "unknown error")")
                    return
                }
                self.install(zipAt: moved, version: release.version)
            }
        }.resume()
    }

    private func install(zipAt zip: URL, version: String) {
        AppState.shared.showToast("Installing Sofa \(version)…")
        let destination = Bundle.main.bundleURL
        let expectedID = Bundle.main.bundleIdentifier

        Task.detached {
            do {
                let script = try Self.prepareSwap(
                    zip: zip,
                    destination: destination,
                    expectedID: expectedID,
                    expectedVersion: version
                )
                await MainActor.run {
                    // Detached so it outlives us, then quit: the script waits for
                    // this process to exit before replacing the bundle.
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/bash")
                    p.arguments = [script.path]
                    try? p.run()
                    NSApp.terminate(nil)
                }
            } catch {
                await MainActor.run {
                    AppState.shared.showToast("Update failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Unpacks the archive, sanity-checks it, and writes the swap script.
    private nonisolated static func prepareSwap(
        zip: URL,
        destination: URL,
        expectedID: String?,
        expectedVersion: String
    ) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sofa-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.badArchive("The download didn’t contain a Sofa app.")
        }
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == expectedID else {
            throw UpdaterError.badArchive("The download isn’t a valid Sofa build.")
        }
        guard bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == expectedVersion else {
            throw UpdaterError.badArchive("The downloaded app has the wrong version.")
        }
        // Detect truncated or modified bundles before the running app quits.
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        let installedRequirement = try designatedRequirement(for: destination)
        let downloadedRequirement = try designatedRequirement(for: newApp)
        guard downloadedRequirement == installedRequirement else {
            throw UpdaterError.badArchive("The downloaded app was signed by a different Sofa identity.")
        }

        let backup = work.appendingPathComponent("previous.app")
        let scriptURL = work.appendingPathComponent("swap.sh")
        let pid = ProcessInfo.processInfo.processIdentifier

        // Move-then-restore rather than rm-then-copy: if the swap fails midway
        // the old app comes back instead of leaving nothing installed.
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        if ! /bin/mv "\(destination.path)" "\(backup.path)"; then exit 1; fi
        if /usr/bin/ditto "\(newApp.path)" "\(destination.path)"; then
          /usr/bin/xattr -dr com.apple.quarantine "\(destination.path)" 2>/dev/null
          /bin/rm -rf "\(backup.path)"
        else
          /bin/rm -rf "\(destination.path)"
          /bin/mv "\(backup.path)" "\(destination.path)"
        fi
        /usr/bin/open "\(destination.path)"
        /bin/rm -f "\(zip.path)"
        (sleep 5; /bin/rm -rf "\(work.path)") &
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    @discardableResult
    private nonisolated static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UpdaterError.command(out.isEmpty ? "Command failed: \(path)" : out)
        }
        return out
    }

    private nonisolated static func designatedRequirement(for app: URL) throws -> String {
        let output = try run("/usr/bin/codesign", ["-dr", "-", app.path])
        guard let requirement = output.split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("designated => ") }) else {
            throw UpdaterError.badArchive("Sofa's code-signing identity could not be verified.")
        }
        return requirement
    }
}
