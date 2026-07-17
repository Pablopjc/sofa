import AppKit
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

    // Also grabs the page's og:image (the poster the site advertises for link
    // previews) so Sofa can show the actual content instead of the app icon —
    // same idea as Control Center's Now Playing artwork. Meta tags are scanned
    // with a loop to avoid nested quotes inside the AppleScript string.
    private static var browserGetJS: String {
        "(function(){\(jsHelpers)" +
        "var v=bv();var t=document.title||'';" +
        "var poster='';var ms=document.getElementsByTagName('meta');" +
        "for(var i=0;i<ms.length;i++){var pr=ms[i].getAttribute('property')||ms[i].getAttribute('name');" +
        "if(pr==='og:image'||pr==='twitter:image'){poster=ms[i].content;break}}" +
        "if(!poster&&v&&v.poster)poster=v.poster;" +
        // YouTube is a single-page app: its og:image often stays on the logo
        // after in-app navigation, so derive the current video's thumbnail
        // straight from the ?v= id instead.
        "if(location.hostname.indexOf('youtube')>-1){var m=location.search.match(/[?&]v=([^&]+)/);" +
        "if(m)poster='https://i.ytimg.com/vi/'+m[1]+'/hqdefault.jpg'}" +
        "if(onNF){var p=nfp();if(p)return (p.getCurrentTime()/1000)+'|'+(v?String(!v.paused):'false')+'|'+poster+'|'+t}" +
        "return v?v.currentTime+'|'+(!v.paused)+'|'+poster+'|'+t:'none'})()"
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

    /// TV, Music and Spotify share iTunes' scripting vocabulary. Spotify also
    /// exposes a cover-art URL; the others don't, so their poster field is empty.
    private static func trackScript(app: String) -> String {
        let artwork = app == "Spotify"
            ? "                try\n                    set art to artwork url of current track\n                end try\n"
            : ""
        return """
        tell application "\(app)"
            set t to ""
            set art to ""
            try
                set t to name of current track
                try
                    set t to t & " — " & (artist of current track)
                end try
        \(artwork)    end try
            return (player position as text) & "|" & ((player state is playing) as text) & "|" & art & "|" & t
        end tell
        """
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
                set t to ""
                try
                    set t to name of document 1
                end try
                return (current time of document 1 as text) & "|" & ((rate of document 1 > 0) as text) & "|" & "" & "|" & t
            end tell
            """
        case .vlc:
            return """
            tell application "VLC"
                set t to ""
                try
                    set t to name of current item
                end try
                return (current time as text) & "|" & (playing as text) & "|" & "" & "|" & t
            end tell
            """
        case .appleTV: return Self.trackScript(app: "TV")
        case .chrome: return Self.chromeAS(Self.browserGetJS)
        case .safari: return Self.safariAS(Self.browserGetJS)
        case .music: return Self.trackScript(app: "Music")
        case .spotify: return Self.trackScript(app: "Spotify")
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

        // Never talk to an app that isn't running: `tell application "X"` would
        // *launch* it, so a player the user just quit would spring back to life.
        // If it's closed, report nothing playing and stay quiet.
        if let bundleID = player.bundleID,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            Task { @MainActor in
                guard self.player == player, AppState.shared.playerChoice == player else { return }
                AppState.shared.extLive = .nothingOpen
                AppState.shared.nowPlaying = nil
                AppState.shared.nowPlayingPoster = nil
                self.lastState = nil
            }
            return
        }

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

        // "time|playing|poster|title" — split with a limit so a title
        // containing a pipe (some pages do) can't corrupt the parse; it's last.
        let parts = out.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let time = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else {
            state.extLive = .nothingOpen
            lastState = nil
            return
        }
        let playing = parts[1].trimmingCharacters(in: .whitespaces) == "true"
        state.extLive = .playing(time: time, isPlaying: playing)

        let poster = parts.count >= 3
            ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let title = parts.count >= 4
            ? String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        updateNowPlaying(title: title, poster: poster, state: state)

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

    /// Publishes the title + poster locally and tells the room, but only when
    /// the title actually changes — the poll runs every 0.7s.
    @MainActor
    private func updateNowPlaying(title: String, poster: String, state: AppState) {
        let cleanTitle = title.isEmpty ? nil : title
        let cleanPoster = poster.hasPrefix("http") ? poster : nil
        state.nowPlayingPoster = cleanPoster
        guard cleanTitle != state.nowPlaying else { return }
        state.nowPlaying = cleanTitle
        if let cleanTitle {
            state.sync.send(SyncMessage(type: "loaded", name: cleanTitle, art: cleanPoster))
        }
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
