import Foundation

/// AppleScript bridge to external media players (QuickTime, VLC, browsers,
/// Music, Spotify). Direct port of the legacy players.js + main.js poll loop.
final class PlayerBridge {
    static let shared = PlayerBridge()

    private var player: PlayerChoice?
    private var timer: Timer?
    private var lastState: (time: Double, playing: Bool, at: Date)?
    private var suppressUntil = Date.distantPast
    private var lastTickSent = Date.distantPast
    private let queue = DispatchQueue(label: "sofa.playerbridge")

    // MARK: - Scripts

    // Browser JS payloads. No double quotes inside (embedded in AppleScript strings).
    // - On netflix.com, uses Netflix's internal player API (the DOM video ignores seeks there).
    // - bv() picks the *right* <video> when a page has several (ads, trailers,
    //   thumbnail previews): prefer one that is playing, else the largest.
    //   This is what makes Prime Video / Disney+ / YouTube reliable.
    private static let jsHelpers =
        "function nfp(){try{var vp=netflix.appContext.state.playerApp.getAPI().videoPlayer;" +
        "var ids=vp.getAllPlayerSessionIds();if(!ids.length)return null;" +
        "return vp.getVideoPlayerBySessionId(ids[0])}catch(e){return null}}" +
        "var onNF=location.hostname.indexOf('netflix')>-1;" +
        "function bv(){var vs=[].slice.call(document.querySelectorAll('video'));" +
        "if(!vs.length)return null;" +
        "var live=vs.filter(function(v){return !v.paused&&!v.ended});" +
        "var pool=live.length?live:vs;" +
        "pool.sort(function(a,b){var x=a.getBoundingClientRect(),y=b.getBoundingClientRect();" +
        "return (y.width*y.height)-(x.width*x.height)});return pool[0]}"

    private static var browserGetJS: String {
        "(function(){\(jsHelpers)" +
        "var v=bv();" +
        "if(onNF){var p=nfp();if(p)return (p.getCurrentTime()/1000)+'|'+(v?String(!v.paused):'false')}" +
        "return v?v.currentTime+'|'+(!v.paused):'none'})()"
    }

    private static func browserCmdJS(_ cmd: String) -> String {
        "(function(){\(jsHelpers)" +
        "if(onNF){var p=nfp();if(p){p.\(cmd)();return}}" +
        "var v=bv();if(v)v.\(cmd)()})()"
    }

    private static func browserSeekJS(_ t: Double) -> String {
        let secs = String(format: "%.3f", t)
        let ms = Int((t * 1000).rounded())
        return "(function(){\(jsHelpers)" +
        "if(onNF){var p=nfp();if(p){p.seek(\(ms));return}}" +
        "var v=bv();if(v)v.currentTime=\(secs)})()"
    }

    private static func chromeAS(_ js: String) -> String {
        "tell application \"Google Chrome\" to return execute active tab of front window javascript \"\(js)\""
    }
    private static func safariAS(_ js: String) -> String {
        "tell application \"Safari\" to return do JavaScript \"\(js)\" in front document"
    }

    private func getScript(for p: PlayerChoice) -> String {
        switch p {
        case .quicktime:
            return """
            tell application "QuickTime Player"
                if (count documents) is 0 then return "none"
                return (current time of document 1 as text) & "|" & ((rate of document 1 > 0) as text)
            end tell
            """
        case .vlc:
            return "tell application \"VLC\" to return (current time as text) & \"|\" & (playing as text)"
        case .appleTV:
            return "tell application \"TV\" to return (player position as text) & \"|\" & ((player state is playing) as text)"
        case .chrome: return Self.chromeAS(Self.browserGetJS)
        case .safari: return Self.safariAS(Self.browserGetJS)
        case .music:
            return "tell application \"Music\" to return (player position as text) & \"|\" & ((player state is playing) as text)"
        case .spotify:
            return "tell application \"Spotify\" to return (player position as text) & \"|\" & ((player state is playing) as text)"
        case .builtin: return ""
        }
    }

    private func playScript(for p: PlayerChoice) -> String {
        switch p {
        case .quicktime: return "tell application \"QuickTime Player\" to play document 1"
        case .vlc: return "tell application \"VLC\" to if not playing then play"
        case .appleTV: return "tell application \"TV\" to play"
        case .chrome: return Self.chromeAS(Self.browserCmdJS("play"))
        case .safari: return Self.safariAS(Self.browserCmdJS("play"))
        case .music: return "tell application \"Music\" to play"
        case .spotify: return "tell application \"Spotify\" to play"
        case .builtin: return ""
        }
    }

    private func pauseScript(for p: PlayerChoice) -> String {
        switch p {
        case .quicktime: return "tell application \"QuickTime Player\" to pause document 1"
        case .vlc: return "tell application \"VLC\" to if playing then play"
        case .appleTV: return "tell application \"TV\" to pause"
        case .chrome: return Self.chromeAS(Self.browserCmdJS("pause"))
        case .safari: return Self.safariAS(Self.browserCmdJS("pause"))
        case .music: return "tell application \"Music\" to pause"
        case .spotify: return "tell application \"Spotify\" to pause"
        case .builtin: return ""
        }
    }

    private func seekScript(for p: PlayerChoice, to t: Double) -> String {
        switch p {
        case .quicktime: return "tell application \"QuickTime Player\" to set current time of document 1 to \(t)"
        case .vlc: return "tell application \"VLC\" to set current time to \(Int(t.rounded()))"
        case .appleTV: return "tell application \"TV\" to set player position to \(t)"
        case .chrome: return Self.chromeAS(Self.browserSeekJS(t))
        case .safari: return Self.safariAS(Self.browserSeekJS(t))
        case .music: return "tell application \"Music\" to set player position to \(t)"
        case .spotify: return "tell application \"Spotify\" to set player position to \(t)"
        case .builtin: return ""
        }
    }

    // MARK: - osascript execution

    /// Runs AppleScript via the osascript CLI off the main thread.
    /// Returns (output, errorText).
    private func osa(_ script: String, completion: @escaping (String?, String?) -> Void) {
        queue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do {
                try proc.run()
            } catch {
                completion(nil, error.localizedDescription)
                return
            }
            proc.waitUntilExit()
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if proc.terminationStatus == 0 {
                completion(stdout, nil)
            } else {
                completion(nil, stderr ?? "osascript failed")
            }
        }
    }

    // MARK: - Lifecycle

    func start(player: PlayerChoice) {
        stop()
        self.player = player
        lastState = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player = nil
        lastState = nil
    }

    // MARK: - Polling (detect local changes → broadcast)

    private var polling = false

    private func poll() {
        guard let player, !polling else { return }
        polling = true
        osa(getScript(for: player)) { [weak self] out, err in
            DispatchQueue.main.async {
                self?.polling = false
                self?.handlePollResult(player: player, out: out, err: err)
            }
        }
    }

    @MainActor
    private func handlePollResult(player: PlayerChoice, out: String?, err: String?) {
        guard self.player == player, let state = AppState.shared as AppState? else { return }
        guard state.playerChoice == player else { return }

        if let err {
            if err.range(of: #"JavaScript (from|through) Apple ?[Ee]vents"#, options: .regularExpression) != nil {
                state.extLive = .blocked(browser: player)
            } else if err.range(of: #"not (allowed|authorized)|Not authorized"#, options: .regularExpression) != nil {
                state.extLive = .notAuthorized
            } else {
                state.extLive = .nothingOpen
            }
            lastState = nil
            return
        }

        guard let out, out != "none", !out.isEmpty else {
            state.extLive = .nothingOpen
            lastState = nil
            return
        }

        let parts = out.split(separator: "|")
        guard parts.count >= 2,
              let time = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else {
            state.extLive = .nothingOpen
            lastState = nil
            return
        }
        let playing = parts[1].trimmingCharacters(in: .whitespaces) == "true"
        state.extLive = .playing(time: time, isPlaying: playing)

        let now = Date()
        if let last = lastState, now >= suppressUntil {
            let expected = last.time + (last.playing ? now.timeIntervalSince(last.at) : 0)
            let jumped = abs(time - expected) > 3
            if playing != last.playing {
                state.sync.send(SyncMessage(type: playing ? "play" : "pause", time: time))
            } else if jumped {
                state.sync.send(SyncMessage(type: "seek", time: time, playing: playing))
            } else if playing, now.timeIntervalSince(lastTickSent) > 5 {
                state.sync.send(SyncMessage(type: "tick", time: time))
                lastTickSent = now
            }
        }
        lastState = (time, playing, now)
    }

    // MARK: - Applying remote commands

    func applyRemote(_ msg: SyncMessage) {
        guard let player else { return }
        suppressUntil = Date().addingTimeInterval(2)
        let latency = msg.latencySeconds
        let time = msg.time ?? 0

        switch msg.type {
        case "play":
            osa(seekScript(for: player, to: time + latency)) { [weak self] _, _ in
                guard let self else { return }
                self.osa(self.playScript(for: player)) { _, _ in }
            }
        case "pause":
            osa(pauseScript(for: player)) { [weak self] _, _ in
                guard let self else { return }
                self.osa(self.seekScript(for: player, to: time)) { _, _ in }
            }
        case "seek":
            let playing = msg.playing ?? false
            osa(seekScript(for: player, to: time + (playing ? latency : 0))) { [weak self] _, _ in
                guard let self else { return }
                let follow = playing ? self.playScript(for: player) : self.pauseScript(for: player)
                self.osa(follow) { _, _ in }
            }
        case "tick":
            osa(getScript(for: player)) { [weak self] out, _ in
                guard let self, let out, out != "none" else { return }
                let parts = out.split(separator: "|")
                guard parts.count >= 2,
                      let cur = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
                      parts[1].trimmingCharacters(in: .whitespaces) == "true" else { return }
                let target = time + latency
                if abs(cur - target) > 2 {
                    self.osa(self.seekScript(for: player, to: target)) { _, _ in }
                }
            }
        default:
            break
        }
        lastState = nil // resync baseline on next poll
    }
}
