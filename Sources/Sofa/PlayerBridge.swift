import AppKit
import Darwin
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
    private var lastPublishedMetadata: String?
    private var lastLivePublishedAt = Date.distantPast
    private var nextPollAllowedAt = Date.distantPast
    private let queue = DispatchQueue(label: "sofa.playerbridge")

    /// Cinema must be removed from the tab that entered it, not whichever tab
    /// happens to be active when the user leaves Theater.
    private enum CinemaTarget {
        case chrome(tabID: Int)
        case safari

        var player: PlayerChoice {
            switch self {
            case .chrome: return .chrome
            case .safari: return .safari
            }
        }
    }
    /// Accessed only from `queue` (including the synchronous termination block).
    private var cinemaTarget: CinemaTarget?

    // MARK: - Scripts

    // Browser JS payloads. No double quotes inside (embedded in AppleScript strings).
    // - On netflix.com, uses Netflix's internal player API (the DOM video ignores seeks there).
    // - bv() picks the *right* <video> when a page has several (ads, trailers,
    //   thumbnail previews). YouTube needs an explicit main-player selector:
    //   its paused page can keep a playing recommendation preview whose video
    //   looks more attractive than the actual movie to a generic heuristic.
    private static let jsHelpers =
        "function nfp(){try{var vp=netflix.appContext.state.playerApp.getAPI().videoPlayer;" +
        "var ids=vp.getAllPlayerSessionIds();if(!ids.length)return null;" +
        "return vp.getVideoPlayerBySessionId(ids[0])}catch(e){return null}}" +
        "function npe(p){try{return p&&typeof p.getElement==='function'?p.getElement():null}catch(e){return null}}" +
        "var onNF=location.hostname.indexOf('netflix')>-1;" +
        "function vpreview(v){try{return !!v.closest('#inline-preview-player,ytd-video-preview," +
        "ytd-video-preview-loader,[id*=preview],[class*=video-preview],[class*=inline-preview]')}catch(e){return false}}" +
        "function vscore(v){var r=v.getBoundingClientRect(),c=getComputedStyle(v);" +
        "if(c.display==='none'||c.visibility==='hidden'||Number(c.opacity)===0)return -1e15;" +
        "var l=Math.max(0,r.left),t=Math.max(0,r.top),rr=Math.min(innerWidth,r.right),bb=Math.min(innerHeight,r.bottom);" +
        "var a=Math.max(0,rr-l)*Math.max(0,bb-t),s=a;" +
        "if(!v.paused&&!v.ended)s+=1e12;if(v.currentTime>1)s+=1e9;if(v.readyState>=2)s+=1e8;" +
        "if(isFinite(v.duration)&&v.duration>30)s+=Math.min(v.duration,21600)*1000;" +
        "if(vpreview(v))s-=1e14;return s}" +
        "function bv(){if(onNF){var np=nfp(),ne=npe(np);" +
        "var nv=ne&&(ne.tagName==='VIDEO'?ne:(ne.querySelector?ne.querySelector('video'):null));if(nv)return nv}" +
        "var vs=[].slice.call(document.querySelectorAll('video'));" +
        "if(!vs.length)return null;" +
        "if(location.hostname.indexOf('youtube')>-1){" +
        "var y=document.querySelector('#movie_player video.html5-main-video,#movie_player video');if(y)return y}" +
        "var pool=vs.filter(function(v){return !vpreview(v)});if(!pool.length)return null;" +
        "pool.sort(function(a,b){return vscore(b)-vscore(a)});return pool[0]}"

    // Also grabs the page's og:image (the poster the site advertises for link
    // previews) so Sofa can show the actual content instead of the app icon —
    // same idea as Control Center's Now Playing artwork. Meta tags are scanned
    // with a loop to avoid nested quotes inside the AppleScript string.
    private static var browserGetJS: String {
        "(function(){\(jsHelpers)" +
        "var v=bv();var t=document.title||'';var mediaURL=location.href;" +
        "var poster='';var ms=document.getElementsByTagName('meta');" +
        "for(var i=0;i<ms.length;i++){var pr=ms[i].getAttribute('property')||ms[i].getAttribute('name');" +
        "if(pr==='og:image'||pr==='twitter:image'){poster=ms[i].content;break}}" +
        "if(!poster&&v&&v.poster)poster=v.poster;" +
        "try{var md=navigator.mediaSession&&navigator.mediaSession.metadata;if(md){" +
        "if(md.title)t=md.title+(md.artist?' — '+md.artist:'');" +
        "if(md.artwork&&md.artwork.length)poster=md.artwork[md.artwork.length-1].src||poster}}catch(e){}" +
        // YouTube is a single-page app: its og:image often stays on the logo
        // after in-app navigation, so derive the current video's thumbnail
        // straight from the ?v= id instead.
        "if(location.hostname.indexOf('youtube')>-1){var m=location.search.match(/[?&]v=([^&]+)/);" +
        "try{var vd=document.querySelector('#movie_player').getVideoData();if(vd&&vd.title)t=vd.title;if(vd&&vd.video_id)m=[null,vd.video_id]}catch(e){}" +
        "if(m){poster='https://i.ytimg.com/vi/'+m[1]+'/hqdefault.jpg';mediaURL='https://www.youtube.com/watch?v='+m[1]}}" +
        "if(onNF){var nm=location.pathname.match(/\\/watch\\/(\\d+)/);if(nm)mediaURL=location.origin+'/watch/'+nm[1];" +
        "var sels=['[data-uia=video-title]','[data-uia=episode-title]','.video-title'];" +
        "for(var j=0;j<sels.length;j++){var el=document.querySelector(sels[j]);if(el&&el.innerText.trim()){t=el.innerText.trim().replace(/\\s*\\n\\s*/g,' — ');break}}}" +
        "var p=onNF?nfp():null;var tm=p?p.getCurrentTime()/1000:(v?v.currentTime:0);" +
        "function fsok(){var f=document.fullscreenElement||document.webkitFullscreenElement;if(!f)return false;" +
        "var h=location.hostname.toLowerCase(),x=null;" +
        "if(h==='youtube.com'||h.endsWith('.youtube.com'))x=document.querySelector('#movie_player');" +
        "else if(h==='netflix.com'||h.endsWith('.netflix.com'))x=document.querySelector('.watch-video--player-view,[data-uia=watch-video]');" +
        "return !!x&&(f===document.documentElement||f===document.body||f===x||f.contains(x)||x.contains(f))}" +
        "if(!v&&!p)return 'none';var data={time:tm,playing:v?!v.paused:false,poster:poster,title:t,url:mediaURL,fullscreen:fsok()};" +
        "return 'SOFAJSON|'+encodeURIComponent(JSON.stringify(data))})()"
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

    // Theater uses the same pattern as Teleparty: a tiny content helper marks
    // the existing site player and applies reversible, site-specific CSS. It
    // never reparents YouTube's #movie_player and never touches Netflix's DRM
    // video/canvas/transform. The identical helper is also shipped as an MV3
    // WebExtension; injecting it here is the zero-install fallback.
    private static var theaterHelperBootstrapJS: String {
        guard let url = Bundle.main.url(
            forResource: "content",
            withExtension: "js",
            subdirectory: "BrowserExtension"
        ), let source = try? String(contentsOf: url, encoding: .utf8) else {
            return "return 'SOFA_ERR|helper-missing';"
        }
        return source
    }

    /// JavaScript is embedded in an AppleScript string literal. Escaping the
    /// literal lets us execute the helper source directly, which also satisfies
    /// YouTube's Trusted Types policy (eval/atob is rejected there).
    private static func appleScriptEscapedJavaScript(_ js: String) -> String {
        js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func theaterCommandJS(
        _ command: String,
        reserveCallColumn: Bool = false
    ) -> String {
        let reserve = reserveCallColumn ? "true" : "false"
        return
            "(function(){var d=document.documentElement;if(!d)return 'SOFA_ERR|no-document';" +
            "if(d.getAttribute('data-sofa-theater-helper')!=='0.1.30-efficiency'){\(theaterHelperBootstrapJS)}" +
            "var w=\(reserve)?'auto':'0';" +
            "d.setAttribute('data-sofa-theater-command','\(command)|'+w);" +
            "d.removeAttribute('data-sofa-theater-status');" +
            "document.dispatchEvent(new Event('sofa-theater-command-0.1.30-efficiency'));" +
            "return d.getAttribute('data-sofa-theater-status')||'SOFA_ERR|helper-no-response'})()"
    }

    private static func cinemaOnJS(reserveCallColumn: Bool) -> String {
        theaterCommandJS("on", reserveCallColumn: reserveCallColumn)
    }

    private static var cinemaOffJS: String { theaterCommandJS("off") }

    private static let cinemaMarkerJS =
        "(function(){return document.documentElement&&document.documentElement.hasAttribute('data-sofa-theater-active')?'SOFA_TARGET':'SOFA_NONE'})()"

    /// Detects a page-owned fullscreen surface that already contains the site
    /// player. Theater must preserve it for Sofa-owned calls, or leave it first
    /// when arranging a third-party call on the desktop.
    private static let compatiblePageFullscreenJS =
        "(function(){var f=document.fullscreenElement||document.webkitFullscreenElement;" +
        "if(!f)return 'SOFA_FALSE';var h=location.hostname.toLowerCase(),t=null;" +
        "if(h==='youtube.com'||h.endsWith('.youtube.com'))t=document.querySelector('#movie_player');" +
        "else if(h==='netflix.com'||h.endsWith('.netflix.com'))t=document.querySelector('.watch-video--player-view,[data-uia=watch-video]');" +
        "if(!t)return 'SOFA_FALSE';return (f===document.documentElement||f===document.body||f===t||f.contains(t)||t.contains(f))?'SOFA_TRUE':'SOFA_FALSE'})()"

    /// Captures Chrome's stable tab id with the result. Safari does not expose a
    /// useful stable tab identifier, so its exit script searches for our private
    /// marker without changing the selected tab or window.
    private static func cinemaOnScript(for player: PlayerChoice, js: String) -> String {
        let safeJS = appleScriptEscapedJavaScript(js)
        switch player {
        case .chrome:
            return """
            if application "Google Chrome" is not running then return "SOFA_APP_NOT_RUNNING"
            tell application "Google Chrome"
                set targetTab to active tab of front window
                set targetID to id of targetTab
                set resultText to execute targetTab javascript "\(safeJS)"
                return "SOFA_TARGET|chrome|" & (targetID as text) & "|" & resultText
            end tell
            """
        case .safari:
            return """
            if application "Safari" is not running then return "SOFA_APP_NOT_RUNNING"
            tell application "Safari"
                set targetTab to current tab of front window
                set resultText to do JavaScript "\(safeJS)" in targetTab
                return "SOFA_TARGET|safari|" & resultText
            end tell
            """
        default:
            return "return \"SOFA_ERR|unsupported\""
        }
    }

    private static func cinemaOffScript(for player: PlayerChoice, target: CinemaTarget?) -> String {
        let safeOffJS = appleScriptEscapedJavaScript(cinemaOffJS)
        switch target {
        case .chrome(let tabID):
            return """
            if application "Google Chrome" is not running then return "SOFA_APP_NOT_RUNNING"
            tell application "Google Chrome"
                repeat with browserWindow in windows
                    repeat with targetTab in tabs of browserWindow
                        try
                            if (id of targetTab as text) is "\(tabID)" then
                                return execute targetTab javascript "\(safeOffJS)"
                            end if
                        end try
                    end repeat
                end repeat
                return "SOFA_ERR|tab-gone"
            end tell
            """
        case .safari:
            return """
            if application "Safari" is not running then return "SOFA_APP_NOT_RUNNING"
            tell application "Safari"
                repeat with browserWindow in windows
                    repeat with targetTab in tabs of browserWindow
                        try
                            set marker to do JavaScript "\(cinemaMarkerJS)" in targetTab
                            if marker is "SOFA_TARGET" then
                                return do JavaScript "\(safeOffJS)" in targetTab
                            end if
                        end try
                    end repeat
                end repeat
                return "SOFA_ERR|tab-gone"
            end tell
            """
        case nil:
            switch player {
            case .chrome: return chromeAS(cinemaOffJS)
            case .safari: return safariAS(cinemaOffJS)
            default: return "return \"SOFA_OK|off|unsupported\""
            }
        }
    }

    private static func parseCinemaOn(output: String?, player: PlayerChoice) -> CinemaTarget? {
        guard let output else { return nil }
        switch player {
        case .chrome:
            let prefix = "SOFA_TARGET|chrome|"
            guard output.hasPrefix(prefix) else { return nil }
            let remainder = output.dropFirst(prefix.count)
            guard let separator = remainder.firstIndex(of: "|") else { return nil }
            let idText = remainder[..<separator]
            let result = remainder[remainder.index(after: separator)...]
            guard let tabID = Int(idText), result.hasPrefix("SOFA_OK|on|"),
                  result.hasSuffix("|pagefs") else { return nil }
            return .chrome(tabID: tabID)
        case .safari:
            let prefix = "SOFA_TARGET|safari|"
            let result = output.dropFirst(prefix.count)
            guard output.hasPrefix(prefix), result.hasPrefix("SOFA_OK|on|"),
                  result.hasSuffix("|pagefs") else { return nil }
            return .safari
        default:
            return nil
        }
    }

    private static func cinemaOffSucceeded(output: String?, error: String?) -> Bool {
        guard error == nil, let output else { return false }
        return output.hasPrefix("SOFA_OK|") || output.hasPrefix("SOFA_ERR|tab-gone")
            || output == "SOFA_APP_NOT_RUNNING"
    }

    /// Fill the browser window with the video (or undo it). No-op for non-browsers.
    func setCinema(
        _ on: Bool,
        for player: PlayerChoice,
        reserveCallColumn: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard player == .chrome || player == .safari else {
            DispatchQueue.main.async { completion?(true) }
            return
        }

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?(false) }
                return
            }

            if on {
                // A failed prior exit must never strand one tab while a second
                // tab enters Cinema. Try the precise old target first.
                if let oldTarget = self.cinemaTarget {
                    if oldTarget.player.isRunning {
                        let oldResult = self.runOSA(
                            Self.cinemaOffScript(for: oldTarget.player, target: oldTarget)
                        )
                        guard Self.cinemaOffSucceeded(output: oldResult.0, error: oldResult.1) else {
                            DispatchQueue.main.async { completion?(false) }
                            return
                        }
                    }
                    self.cinemaTarget = nil
                }

                guard player.isRunning else {
                    DispatchQueue.main.async { completion?(false) }
                    return
                }
                let js = Self.cinemaOnJS(reserveCallColumn: reserveCallColumn)
                let result = self.runOSA(Self.cinemaOnScript(for: player, js: js))
                if result.1 == nil,
                   let parsed = Self.parseCinemaOn(output: result.0, player: player) {
                    self.cinemaTarget = parsed
                    DispatchQueue.main.async { completion?(true) }
                } else {
                    DispatchQueue.main.async { completion?(false) }
                }
                return
            }

            let effectivePlayer = self.cinemaTarget?.player ?? player
            guard effectivePlayer.isRunning else {
                self.cinemaTarget = nil
                DispatchQueue.main.async { completion?(true) }
                return
            }
            let result = self.runOSA(
                Self.cinemaOffScript(for: effectivePlayer, target: self.cinemaTarget)
            )
            let ok = Self.cinemaOffSucceeded(output: result.0, error: result.1)
            if ok { self.cinemaTarget = nil }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// AppKit does not keep an app alive for asynchronous cleanup once
    /// `applicationWillTerminate` returns. Run the tiny restore script to
    /// completion so quitting Sofa can never leave the website inside its DOM
    /// stage until the tab is reloaded.
    func clearCinemaBeforeTermination(for player: PlayerChoice?) {
        // Serialize behind any pending Cinema-on script, then remove the exact
        // target before AppKit lets the process terminate. This also runs after
        // a normal Exit whose async off may still be queued.
        queue.sync {
            guard let effectivePlayer = cinemaTarget?.player ?? player,
                  effectivePlayer == .chrome || effectivePlayer == .safari else { return }
            guard effectivePlayer.isRunning else {
                cinemaTarget = nil
                return
            }
            let result = runOSA(
                Self.cinemaOffScript(for: effectivePlayer, target: cinemaTarget),
                timeout: 3.0
            )
            if Self.cinemaOffSucceeded(output: result.0, error: result.1) {
                cinemaTarget = nil
            }
        }
    }

    func compatibleBrowserPageFullscreen(
        for player: PlayerChoice,
        completion: @escaping (Bool) -> Void
    ) {
        guard player.isBrowser, player.isRunning else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let finish: (String?, String?) -> Void = { output, error in
            DispatchQueue.main.async { completion(error == nil && output == "SOFA_TRUE") }
        }
        switch player {
        case .chrome:
            osa(
                Self.chromeAS(Self.compatiblePageFullscreenJS),
                requiring: player,
                completion: finish
            )
        case .safari:
            osa(
                Self.safariAS(Self.compatiblePageFullscreenJS),
                requiring: player,
                completion: finish
            )
        default:
            DispatchQueue.main.async { completion(false) }
        }
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
        let safeJS = appleScriptEscapedJavaScript(js)
        return "if application \"Google Chrome\" is not running then return \"SOFA_APP_NOT_RUNNING\"\n"
            + "tell application \"Google Chrome\" to return execute active tab of front window javascript \"\(safeJS)\""
    }
    private static func safariAS(_ js: String) -> String {
        let safeJS = appleScriptEscapedJavaScript(js)
        return "if application \"Safari\" is not running then return \"SOFA_APP_NOT_RUNNING\"\n"
            + "tell application \"Safari\" to return do JavaScript \"\(safeJS)\" in front document"
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
    private func osa(
        _ script: String,
        requiring runningPlayer: PlayerChoice? = nil,
        completion: @escaping (String?, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion(nil, "Player bridge is unavailable")
                return
            }
            if let runningPlayer, !runningPlayer.isRunning {
                completion(nil, "SOFA_APP_NOT_RUNNING")
                return
            }
            let result = self.runOSA(script)
            completion(result.0, result.1)
        }
    }

    /// `waitUntilExit()` can hang forever if a browser stops answering Apple
    /// Events. Bound every command, including synchronous termination cleanup.
    private func runOSA(_ script: String, timeout: TimeInterval = 5.0) -> (String?, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let finished = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in finished.signal() }
        do {
            try proc.run()
        } catch {
            return (nil, error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            if finished.wait(timeout: .now() + 0.75) == .timedOut {
                Darwin.kill(proc.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.75)
            }
            return (nil, "osascript timed out")
        }

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationStatus == 0 {
            return (stdout, nil)
        }
        return (nil, (stderr?.isEmpty == false ? stderr : nil) ?? "osascript failed")
    }

    // MARK: - Lifecycle

    func start(player: PlayerChoice) {
        stop()
        self.player = player
        lastState = nil
        lastPublishedMetadata = nil
        lastLivePublishedAt = .distantPast
        nextPollAllowedAt = .distantPast
        let pollTimer = Timer(timeInterval: 0.85, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer.tolerance = 0.05
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player = nil
        lastState = nil
        lastPublishedMetadata = nil
        lastLivePublishedAt = .distantPast
        nextPollAllowedAt = .distantPast
    }

    /// Resume a slow/idle poll immediately after an app launch or a remote
    /// command. This keeps the adaptive backoff invisible to the viewer.
    func wakePolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player != nil else { return }
            self.nextPollAllowedAt = .distantPast
            self.poll()
        }
    }

    // MARK: - Polling (detect local changes → broadcast)

    private var polling = false

    private func poll() {
        guard let player, !polling, Date() >= nextPollAllowedAt else { return }

        // Never talk to an app that isn't running: `tell application "X"` would
        // *launch* it, so a player the user just quit would spring back to life.
        // If it's closed, report nothing playing and stay quiet.
        if let bundleID = player.bundleID,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            Task { @MainActor in
                guard self.player == player, AppState.shared.playerChoice == player else { return }
                if AppState.shared.extLive != .nothingOpen { AppState.shared.extLive = .nothingOpen }
                if AppState.shared.nowPlaying != nil { AppState.shared.nowPlaying = nil }
                if AppState.shared.nowPlayingPoster != nil { AppState.shared.nowPlayingPoster = nil }
                if AppState.shared.nowPlayingURL != nil { AppState.shared.nowPlayingURL = nil }
                AppState.shared.playerBridgeReportedFullscreen(false, for: player)
                self.lastState = nil
                self.nextPollAllowedAt = Date().addingTimeInterval(4)
            }
            return
        }

        polling = true
        osa(getScript(for: player), requiring: player) { [weak self] out, err in
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
                let next = ExtLiveState.blocked(browser: player)
                if state.extLive != next { state.extLive = next }
            } else if err.range(of: #"not (allowed|authorized)|Not authorized"#, options: .regularExpression) != nil {
                if state.extLive != .notAuthorized { state.extLive = .notAuthorized }
            } else {
                if state.extLive != .nothingOpen { state.extLive = .nothingOpen }
            }
            lastState = nil
            // Permission errors and a temporarily busy browser should not burn
            // CPU by spawning osascript continuously. Do not report fullscreen
            // false here: a transient Apple Event timeout must not close Theater.
            nextPollAllowedAt = Date().addingTimeInterval(3)
            return
        }

        guard let out, out != "none", !out.isEmpty else {
            if state.extLive != .nothingOpen { state.extLive = .nothingOpen }
            state.playerBridgeReportedFullscreen(false, for: player)
            lastState = nil
            nextPollAllowedAt = Date().addingTimeInterval(3)
            return
        }

        let media = parseMediaResult(out)
        guard let media else {
            if state.extLive != .nothingOpen { state.extLive = .nothingOpen }
            state.playerBridgeReportedFullscreen(false, for: player)
            lastState = nil
            nextPollAllowedAt = Date().addingTimeInterval(3)
            return
        }
        let time = media.time
        let playing = media.playing
        let now = Date()
        let playingChanged: Bool
        if case .playing(_, let previousPlaying) = state.extLive {
            playingChanged = previousPlaying != playing
        } else {
            playingChanged = true
        }
        if playingChanged || now.timeIntervalSince(lastLivePublishedAt) >= 1.5 {
            state.extLive = .playing(time: time, isPlaying: playing)
            lastLivePublishedAt = now
        }
        state.playerBridgeReportedFullscreen(media.fullscreen, for: player)
        updateNowPlaying(
            title: media.title,
            poster: media.poster,
            url: media.url,
            time: time,
            playing: playing,
            state: state
        )

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
        // Keep controls and sync crisp during playback, while avoiding thousands
        // of short-lived osascript processes when a movie is paused.
        nextPollAllowedAt = now.addingTimeInterval(playing ? 0.8 : 1.5)
    }

    /// Publishes the title + poster locally and tells the room, but only when
    /// the title actually changes — the poll runs roughly once per second.
    @MainActor
    private func updateNowPlaying(
        title: String,
        poster: String,
        url: String?,
        time: Double,
        playing: Bool,
        state: AppState
    ) {
        let cleanTitle = title.isEmpty ? nil : title
        let cleanPoster = poster.hasPrefix("http") ? poster : nil
        let cleanURL = url.flatMap(Self.canonicalMediaURL)
        if state.nowPlayingPoster != cleanPoster { state.nowPlayingPoster = cleanPoster }
        if state.nowPlayingURL != cleanURL { state.nowPlayingURL = cleanURL }
        if state.nowPlaying != cleanTitle { state.nowPlaying = cleanTitle }
        let signature = [cleanTitle ?? "", cleanPoster ?? "", cleanURL ?? ""].joined(separator: "\u{1F}")
        guard signature != lastPublishedMetadata else { return }
        lastPublishedMetadata = signature
        if let cleanTitle {
            state.sync.send(SyncMessage(
                type: "loaded", time: time, playing: playing,
                name: cleanTitle, art: cleanPoster, url: cleanURL
            ))
        }
    }

    private struct MediaResult {
        let time: Double
        let playing: Bool
        let poster: String
        let title: String
        let url: String?
        let fullscreen: Bool?
    }

    private func parseMediaResult(_ output: String) -> MediaResult? {
        if output.hasPrefix("SOFAJSON|"),
           let decoded = String(output.dropFirst(9)).removingPercentEncoding,
           let data = decoded.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let time = (object["time"] as? NSNumber)?.doubleValue,
           time.isFinite {
            return MediaResult(
                time: time,
                playing: (object["playing"] as? Bool) ?? false,
                poster: object["poster"] as? String ?? "",
                title: object["title"] as? String ?? "",
                url: object["url"] as? String,
                fullscreen: object["fullscreen"] as? Bool
            )
        }
        let parts = output.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let time = Double(parts[0].replacingOccurrences(of: ",", with: ".")),
              time.isFinite else { return nil }
        return MediaResult(
            time: time,
            playing: parts[1].trimmingCharacters(in: .whitespaces) == "true",
            poster: parts.count >= 3 ? String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines) : "",
            title: parts.count >= 4 ? String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines) : "",
            url: nil,
            fullscreen: nil
        )
    }

    private static func canonicalMediaURL(_ raw: String) -> String? {
        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil else { return nil }
        components.fragment = nil
        let host = components.host?.lowercased() ?? ""
        if host.contains("netflix.com"),
           let match = components.path.range(of: #"/watch/\d+"#, options: .regularExpression) {
            components.path = String(components.path[match])
            components.query = nil
        }
        if host == "youtu.be" || host.hasSuffix("youtube.com") {
            let id: String? = host == "youtu.be"
                ? components.path.split(separator: "/").first.map(String.init)
                : components.queryItems?.first(where: { $0.name == "v" })?.value
            if let id, !id.isEmpty {
                components.scheme = "https"
                components.host = "www.youtube.com"
                components.path = "/watch"
                components.queryItems = [URLQueryItem(name: "v", value: id)]
            }
        }
        return components.url?.absoluteString
    }

    // MARK: - Applying remote commands

    /// Local pause without a remote command (auto-pause when a friend drops).
    /// Suppressed from the poll so it isn't re-broadcast as a user action.
    func pauseLocally() {
        guard let player, player.isRunning else { return }
        suppressUntil = Date().addingTimeInterval(2)
        osa(pauseScript(for: player), requiring: player) { _, _ in }
        lastState = nil
        wakePolling()
    }

    /// A play/pause/seek that silently fails means both sides drift apart with
    /// no explanation — the worst failure mode a sync app can have. Surface it,
    /// throttled to one toast per minute. Runs on the bridge's serial queue.
    private var lastCommandErrorReportedAt = Date.distantPast
    private func noteCommandResult(_ error: String?, player: PlayerChoice) {
        guard let error, error != "SOFA_APP_NOT_RUNNING" else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCommandErrorReportedAt) > 60 else { return }
        lastCommandErrorReportedAt = now
        let hint: String
        if error.contains("1743") || error.localizedCaseInsensitiveContains("not authorized") {
            hint = "macOS blocked Sofa from controlling \(player.shortLabel). Fix it in System Settings → Privacy & Security → Automation."
        } else if error.contains("timed out") {
            hint = "\(player.shortLabel) didn’t respond — sync may drift until it recovers."
        } else {
            hint = "Sofa couldn’t control \(player.shortLabel) — sync may drift."
        }
        DispatchQueue.main.async { AppState.shared.showToast(hint) }
    }

    func applyRemote(_ msg: SyncMessage) {
        guard let player, player.isRunning else { return }
        suppressUntil = Date().addingTimeInterval(2)
        let latency = msg.latencySeconds
        let time = msg.time ?? 0

        switch msg.type {
        case "play":
            osa(seekScript(for: player, to: time + latency), requiring: player) { [weak self] _, err in
                guard let self else { return }
                self.noteCommandResult(err, player: player)
                self.osa(self.playScript(for: player), requiring: player) { _, err2 in
                    self.noteCommandResult(err2, player: player)
                }
            }
        case "pause":
            osa(pauseScript(for: player), requiring: player) { [weak self] _, err in
                guard let self else { return }
                self.noteCommandResult(err, player: player)
                self.osa(self.seekScript(for: player, to: time), requiring: player) { _, _ in }
            }
        case "seek":
            let playing = msg.playing ?? false
            osa(
                seekScript(for: player, to: time + (playing ? latency : 0)),
                requiring: player
            ) { [weak self] _, err in
                guard let self else { return }
                self.noteCommandResult(err, player: player)
                let follow = playing ? self.playScript(for: player) : self.pauseScript(for: player)
                self.osa(follow, requiring: player) { _, _ in }
            }
        case "tick":
            osa(getScript(for: player), requiring: player) { [weak self] out, _ in
                guard let self, let out, out != "none",
                      let media = self.parseMediaResult(out), media.playing else { return }
                let cur = media.time
                let target = time + latency
                if abs(cur - target) > 2 {
                    self.osa(
                        self.seekScript(for: player, to: target),
                        requiring: player
                    ) { _, _ in }
                }
            }
        default:
            break
        }
        lastState = nil // resync baseline on next poll
        wakePolling()
    }

    /// Opens the friend's canonical page only after an explicit click, then
    /// waits for the site's real player before seeking to the shared position.
    func openRemoteMedia(url: URL, player: PlayerChoice, time: Double, playing: Bool) {
        guard player.isBrowser,
              let canonical = Self.canonicalMediaURL(url.absoluteString) else { return }
        let escaped = canonical.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch player {
        case .safari:
            script = "tell application \"Safari\" to open location \"\(escaped)\""
        case .chrome:
            script = "tell application \"Google Chrome\" to open location \"\(escaped)\""
        default:
            return
        }
        osa(script) { [weak self] _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    AppState.shared.showToast("Couldn’t open your friend’s video: \(error)")
                }
                return
            }
            self.waitForRemotePlayer(
                player: player, time: time, playing: playing, attemptsRemaining: 30
            )
        }
    }

    private func waitForRemotePlayer(
        player: PlayerChoice,
        time: Double,
        playing: Bool,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else {
            DispatchQueue.main.async {
                AppState.shared.showToast("The video page opened, but its player is not ready yet.")
            }
            return
        }
        queue.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self else { return }
            let result = self.runOSA(self.getScript(for: player))
            if let output = result.0, output != "none", self.parseMediaResult(output) != nil {
                DispatchQueue.main.async {
                    guard AppState.shared.playerChoice == player else { return }
                    self.applyRemote(SyncMessage(
                        type: "seek", time: time, playing: playing,
                        name: AppState.shared.friendNowPlaying,
                        art: AppState.shared.friendNowPlayingArt,
                        url: AppState.shared.friendNowPlayingURL
                    ))
                    AppState.shared.showToast("Opened your friend’s video and synced the time.")
                }
            } else {
                self.waitForRemotePlayer(
                    player: player, time: time, playing: playing,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
    }
}
