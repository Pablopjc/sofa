import AppKit
import Foundation

/// Runs the player-control AppleScripts in-process instead of spawning
/// `/usr/bin/osascript` for every call.
///
/// Why this exists: a reaction reaches a friend in a few hundred milliseconds
/// because it is pure network. A pause does not — Sofa has to *notice* the
/// pause first, and it noticed by polling the player. Measured on this Mac,
/// one `osascript` process costs ~195 ms (worst case 1.2 s) while the same
/// script compiled once and executed in-process costs ~8 ms. That 24x is what
/// forced the old 0.8–1.5 s poll gap: a fast poll was simply unaffordable when
/// each sample forked a process. Make the sample cheap and the poll can run
/// several times a second, which is what actually decides how quickly your
/// friend sees you hit pause.
///
/// Threading: `NSAppleScript` is not thread-safe, so every compile and execute
/// happens on one dedicated thread that owns a run loop (Apple Event replies
/// need one). Callers block on a semaphore with the same timeout the process
/// path used.
///
/// Safety valve: a player that hangs would block the shared thread, and unlike
/// a child process an in-process script cannot be killed. So a call that times
/// out marks the runner degraded, and `run` then reports "unavailable" until
/// the stuck script returns — PlayerBridge falls back to the killable
/// `osascript` process for those calls. Correctness never depends on the fast
/// path being available.
/// Dev-only latency trace. `SOFA_TRACE_SYNC=1` appends timestamped lines to
/// /tmp/sofa-trace.log so the delay between a local player change and the
/// broadcast can be measured for real instead of estimated. Off — and free —
/// in every normal run.
enum SyncTrace {
    static let enabled = ProcessInfo.processInfo.environment["SOFA_TRACE_SYNC"] != nil
    private static let handle: FileHandle? = {
        guard enabled else { return nil }
        let path = "/tmp/sofa-trace.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }()

    static func log(_ event: String) {
        guard enabled, let handle else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, event)
        handle.write(Data(line.utf8))
    }
}

final class ScriptRunner {
    static let shared = ScriptRunner()

    private let thread: Thread
    private let lock = NSLock()
    /// Touched only on `thread`; compiling is the expensive part, so keep them.
    private var compiled: [String: NSAppleScript] = [:]
    /// Number of executions started that have not yet returned. Anything above
    /// zero when a call times out means the thread is stuck.
    private var inFlight = 0

    private init() {
        let worker = Worker()
        let t = Thread {
            let runLoop = RunLoop.current
            // A port keeps the run loop from returning immediately when idle.
            runLoop.add(NSMachPort(), forMode: .default)
            while !Thread.current.isCancelled {
                runLoop.run(mode: .default, before: .distantFuture)
            }
        }
        t.name = "com.pablo.sofa.applescript"
        t.qualityOfService = .userInitiated
        t.stackSize = 512 * 1024
        t.start()
        thread = t
        worker.owner = self
        self.worker = worker
    }

    private var worker: Worker!

    /// The object whose selector is performed on the dedicated thread.
    /// `NSAppleScript` execution must not hop threads between calls.
    private final class Worker: NSObject {
        weak var owner: ScriptRunner?

        @objc func execute(_ box: Box) {
            defer { box.done.signal() }
            guard let owner else {
                box.error = "Script runner is unavailable"
                return
            }
            let script: NSAppleScript
            if let existing = owner.compiled[box.source] {
                script = existing
            } else {
                guard let fresh = NSAppleScript(source: box.source) else {
                    box.error = "Could not compile the player script"
                    return
                }
                var compileError: NSDictionary?
                if !fresh.compileAndReturnError(&compileError) {
                    box.error = ScriptRunner.message(from: compileError)
                    return
                }
                owner.compiled[box.source] = fresh
                script = fresh
            }
            var runError: NSDictionary?
            let result = script.executeAndReturnError(&runError)
            if let runError {
                box.error = ScriptRunner.message(from: runError)
            } else {
                box.output = ScriptRunner.text(from: result)
            }
        }
    }

    private final class Box: NSObject {
        let source: String
        var output: String?
        var error: String?
        let done = DispatchSemaphore(value: 0)
        init(source: String) { self.source = source }
    }

    /// Preserves the wording the callers already match on: PlayerBridge greps
    /// the message for "1743", "not authorized" and the JavaScript-from-Apple-
    /// Events phrasing to decide which fix to suggest, so the numeric code has
    /// to travel with the text.
    private static func message(from info: NSDictionary?) -> String {
        let text = (info?[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed"
        if let number = info?[NSAppleScript.errorNumber] as? Int {
            return "\(text) (\(number))"
        }
        return text
    }

    /// `osascript` prints the plain value; mirror that so parsers are unchanged.
    private static func text(from descriptor: NSAppleEventDescriptor?) -> String? {
        guard let descriptor else { return nil }
        if let s = descriptor.stringValue {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A list comes back as a record of items; join like osascript does.
        if descriptor.numberOfItems > 0 {
            var parts: [String] = []
            for i in 1...descriptor.numberOfItems {
                parts.append(descriptor.atIndex(i)?.stringValue ?? "")
            }
            return parts.joined(separator: ", ")
        }
        return nil
    }

    /// Returns `nil` when the fast path is unavailable and the caller should use
    /// the process fallback. Otherwise returns (stdout, stderr)-shaped output.
    func run(_ source: String, timeout: TimeInterval) -> (String?, String?)? {
        lock.lock()
        let stuck = inFlight > 0
        lock.unlock()
        // Serialised by design: a second caller arriving while the thread is
        // still inside a slow script should not queue behind it, because the
        // whole point here is latency. Send it down the killable path instead.
        if stuck { return nil }

        lock.lock(); inFlight += 1; lock.unlock()
        let box = Box(source: source)
        worker.perform(#selector(Worker.execute(_:)), on: thread, with: box, waitUntilDone: false)

        if box.done.wait(timeout: .now() + timeout) == .timedOut {
            // Leave inFlight raised: it clears itself if the script ever returns,
            // and until then every caller takes the process path.
            DispatchQueue.global().async { [weak self] in
                box.done.wait()
                self?.lock.lock(); self?.inFlight -= 1; self?.lock.unlock()
            }
            return nil
        }
        lock.lock(); inFlight -= 1; lock.unlock()
        return (box.output, box.error)
    }
}
