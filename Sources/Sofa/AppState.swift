import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Asks the app delegate to hide the menu bar panel (eg. entering Theater).
    static let sofaHidePanel = Notification.Name("SofaHidePanel")
    static let sofaShowPanel = Notification.Name("SofaShowPanel")
}

/// Which player Sofa is syncing.
enum PlayerChoice: String, CaseIterable, Identifiable {
    case quicktime, vlc, appleTV, chrome, safari, music, spotify, builtin
    var id: String { rawValue }

    var label: String {
        switch self {
        case .quicktime: return "QuickTime Player"
        case .vlc: return "VLC"
        case .appleTV: return "Apple TV"
        case .chrome: return "Google Chrome — YouTube, Netflix, Prime Video…"
        case .safari: return "Safari — YouTube, Netflix, Prime Video…"
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        case .builtin: return "Sofa’s built-in player"
        }
    }

    var hint: String {
        switch self {
        case .quicktime: return "Open your movie in QuickTime as usual — Sofa mirrors every play, pause and skip."
        case .vlc: return "Open your movie in VLC as usual — Sofa mirrors every play, pause and skip."
        case .appleTV: return "Play your movie in the Apple TV app as usual — Sofa mirrors every play, pause and skip."
        case .chrome: return "Keep the video tab in front (YouTube, Netflix, Prime Video, Disney+…). One-time setup: View → Developer → Allow JavaScript from Apple Events."
        case .safari: return "Keep the video tab in front (YouTube, Netflix, Prime Video, Disney+…). One-time setup: Develop → Allow JavaScript from Apple Events."
        case .music: return "Play your music in Apple Music as usual — playback stays in sync."
        case .spotify: return "Play your music in Spotify as usual — playback stays in sync."
        case .builtin: return "Open the same file on both Macs. Playback stays in sync."
        }
    }

    /// Clean app name (no marketing suffix) for the source list.
    var shortLabel: String {
        switch self {
        case .quicktime: return "QuickTime Player"
        case .vlc: return "VLC"
        case .appleTV: return "Apple TV"
        case .chrome: return "Google Chrome"
        case .safari: return "Safari"
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        case .builtin: return "Sofa’s built-in player"
        }
    }

    /// Bundle identifier used to detect whether the app is currently running.
    var bundleID: String? {
        switch self {
        case .quicktime: return "com.apple.QuickTimePlayerX"
        case .vlc: return "org.videolan.vlc"
        case .appleTV: return "com.apple.TV"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .builtin: return nil
        }
    }

    /// The real app icon (for the source list), or nil for the built-in player.
    private static let appIconCache = NSCache<NSString, NSImage>()

    @MainActor var appIcon: NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        if let cached = Self.appIconCache.object(forKey: bundleID as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        Self.appIconCache.setObject(image, forKey: bundleID as NSString)
        return image
    }

    /// Players Sofa can drive (excludes the built-in player).
    static var externalPlayers: [PlayerChoice] {
        [.quicktime, .vlc, .appleTV, .chrome, .safari, .music, .spotify]
    }

    /// Theater needs a window that actually contains moving video.
    var supportsTheater: Bool {
        switch self {
        case .quicktime, .vlc, .appleTV, .chrome, .safari: return true
        case .music, .spotify, .builtin: return false
        }
    }

    var isBrowser: Bool { self == .chrome || self == .safari }

    /// AppleScript's `tell application` launches a target that is not running.
    /// Every background probe and remote command must check this first.
    var isRunning: Bool {
        guard let bundleID else { return self == .builtin }
        return !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).isEmpty
    }
}

/// Live state of the external player shown in the UI.
enum ExtLiveState: Equatable {
    case searching
    case nothingOpen
    case blocked(browser: PlayerChoice)
    case notAuthorized
    case playing(time: Double, isPlaying: Bool)
}

enum RoomTransport: Equatable {
    case online
    case lan
    case test
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Your name, shown to friends in the room. Persisted across launches.
    @Published var displayName: String = UserDefaults.standard.string(forKey: "SofaDisplayName")
        ?? NSFullUserName().components(separatedBy: " ").first ?? "Me" {
        didSet {
            UserDefaults.standard.set(displayName, forKey: "SofaDisplayName")
            SocialService.shared.displayNameChanged(displayName)
        }
    }

    /// Friends currently in the room (peer id → name), kept fresh by presence.
    struct Friend: Identifiable, Equatable {
        let id: String
        var name: String
        var lastSeen: Date
        static func == (a: Friend, b: Friend) -> Bool { a.id == b.id && a.name == b.name }
    }
    @Published var friends: [Friend] = []

    // Room
    @Published var inRoom = false
    @Published var isHosting = false
    @Published var isTestMode = false
    @Published var statusLabel = ""
    @Published var peerCount = 0
    @Published var disconnected = false
    @Published var inviteLink = ""
    @Published var inviteCode = ""
    @Published var joinAddress = ""
    @Published var joinError: String?
    @Published var joining = false
    @Published var hosting = false
    @Published var hostError: String?
    @Published private(set) var roomTransport: RoomTransport?
    private var roomOperationID: UUID?

    var roomIsOnline: Bool { roomTransport == .online }

    // Player
    @Published var playerChoice: PlayerChoice = .quicktime
    @Published var extLive: ExtLiveState = .searching
    /// What's playing here, and what our friend says is playing on their side.
    @Published var nowPlaying: String?
    @Published var nowPlayingPoster: String?
    @Published var nowPlayingURL: String?
    @Published var friendNowPlaying: String?
    @Published var friendNowPlayingArt: String?
    @Published var friendNowPlayingURL: String?
    @Published var friendPlaybackTime: Double?
    @Published var friendIsPlaying: Bool?
    private var friendPlaybackUpdatedAt = Date()

    // Auto-detected active players (running apps), refreshed while in a room.
    @Published var detectedSources: [PlayerChoice] = []
    /// Running media apps that can't be automated (shown as an explanation).
    @Published var unsupportedNotice: String?
    /// The video-call app currently running, if any (for the Arrange layout).
    @Published var detectedCallApp: WindowArranger.CallApp?
    private var detectTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    // Audio
    @Published var systemVolume: Double = 50
    @Published var movieVolume: Double = 100
    @Published var callVolume: Double = UserDefaults.standard.object(
        forKey: "SofaFaceTimeVolume"
    ) as? Double ?? 100
    private var callVolumeWorkItem: DispatchWorkItem?

    // Toast
    @Published var toast: String?
    private var toastTimer: Timer?

    // Keep the panel open on blur while something is loaded/playing.
    var mediaActive = false

    let sync = SyncEngine()
    let builtin = BuiltinPlayer()
    let testFriend = TestFriend()

    private init() {
        sync.state = self
        builtin.state = self
        SystemVolume.get { [weak self] v in
            DispatchQueue.main.async { self?.systemVolume = Double(v) }
        }
    }

    /// Returns true when this peer wasn't known yet.
    func upsertFriend(id: String, name: String) -> Bool {
        if let i = friends.firstIndex(where: { $0.id == id }) {
            friends[i].name = name
            friends[i].lastSeen = Date()
            return false
        }
        friends.append(Friend(id: id, name: name, lastSeen: Date()))
        showToast("\(name) joined the party")
        return true
    }

    func removeFriend(id: String) {
        if let i = friends.firstIndex(where: { $0.id == id }) {
            let name = friends[i].name
            friends.remove(at: i)
            showToast("\(name) left")
        }
    }

    func pruneFriends(olderThan seconds: TimeInterval) {
        friends.removeAll { Date().timeIntervalSince($0.lastSeen) > seconds }
    }

    func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.toast = nil }
        }
    }

    var peersText: String {
        if !friends.isEmpty {
            return "· with " + friends.map(\.name).joined(separator: ", ")
        }
        let others = max(0, peerCount - 1)
        if isTestMode { return others > 0 ? "· simulated friend" : "· connecting…" }
        if others == 0 { return "· waiting…" }
        return "· \(others) friend\(others > 1 ? "s" : "")"
    }

    // MARK: - Room lifecycle

    func hostRoom() {
        guard !hosting, !joining, !inRoom else { return }
        let operationID = UUID()
        roomOperationID = operationID
        hosting = true
        hostError = nil
        joinError = nil

        sync.startOnlineHosting { [weak self] result in
            guard let self, self.roomOperationID == operationID else { return }
            self.hosting = false
            switch result {
            case .success(let room):
                self.inviteLink = "sofa://join/v1/\(room.roomID)/\(room.secret)"
                self.inviteCode = room.roomID
                self.isHosting = true
                self.roomTransport = .online
                self.enterRoom(label: "Hosting online")
            case .failure(let error):
                self.sync.stop()
                self.hostError = "Could not start an online party. \(error.localizedDescription)"
            }
        }
    }

    /// Explicit legacy mode for a trusted local network. Normal parties use the
    /// public WSS relay; this remains useful offline and keeps old invites valid.
    func hostLANRoom() {
        guard !hosting, !joining, !inRoom else { return }
        let operationID = UUID()
        roomOperationID = operationID
        hosting = true
        hostError = nil
        joinError = nil
        sync.startHosting { [weak self] result in
            guard let self, self.roomOperationID == operationID else { return }
            self.hosting = false
            switch result {
            case .success:
                let ip = primaryIP()
                self.inviteLink = "sofa://join/\(ip):\(SyncEngine.port)/\(self.sync.roomToken ?? "")"
                self.inviteCode = self.sync.roomToken ?? ""
                self.isHosting = true
                self.roomTransport = .lan
                self.enterRoom(label: "Hosting locally")
            case .failure(let error):
                self.sync.stop()
                self.roomOperationID = nil
                self.hostError = "Could not start the local party. \(error.localizedDescription)"
            }
        }
    }

    func join(target: String? = nil) {
        guard !hosting, !joining, !inRoom else { return }
        let raw = target ?? joinAddress
        guard let target = Self.parseTarget(raw) else {
            joinError = "That invite link is not valid. Ask your friend to copy the full link again."
            return
        }
        let operationID = UUID()
        roomOperationID = operationID
        joinError = nil
        hostError = nil
        joining = true

        let completion: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            guard self.roomOperationID == operationID else { return }
            self.joining = false
            if ok {
                self.roomTransport = target.isOnline ? .online : .lan
                self.enterRoom(label: target.isOnline ? "Connected online" : "Connected locally")
            } else if target.token == nil {
                self.joinError = "Could not join. Use the full invite link — it includes the room code."
            } else {
                self.joinError = "Could not connect. Check the link and that your friend's party is still open."
            }
        }

        switch target {
        case .online(let roomID, let secret):
            sync.connectOnline(roomID: roomID, secret: secret, completion: completion)
        case .lan(let address, let token):
            sync.connect(to: address, token: token, completion: completion)
        }
    }

    static func parseTarget(_ text: String) -> RoomTarget? {
        RoomTarget.parse(text)
    }

    private func enterRoom(label: String) {
        inRoom = true
        disconnected = false
        statusLabel = label
        startDetecting()
        // Default to whatever is already open, if the current pick isn't running.
        if let first = detectedSources.first, !detectedSources.contains(playerChoice) {
            playerChoice = first
        }
        applyPlayerChoice()
    }

    /// Called by SyncEngine only for an online session that had already passed
    /// authentication. Initial join failures stay in the idle UI instead.
    func markOnlineReconnecting() {
        guard inRoom, roomTransport == .online else { return }
        if !disconnected {
            showToast("Connection lost — reconnecting…")
        }
        disconnected = true
        statusLabel = "Reconnecting…"
    }

    func markOnlineConnectionRestored() {
        guard inRoom, roomTransport == .online else { return }
        disconnected = false
        statusLabel = isHosting ? "Hosting online" : "Connected online"
        showToast("Connection restored")
    }

    /// A LAN listener cannot recover its fixed port while the room is active.
    /// Remove the dead invite immediately instead of leaving a copyable link
    /// that no friend can use.
    func localPartyStoppedUnexpectedly() {
        guard inRoom, (roomTransport == .lan || roomTransport == .test) else { return }
        let wasTestMode = isTestMode
        let message = wasTestMode
            ? "Test Zone stopped. Open it again to retry."
            : "The local party stopped. Start it again to create a new invite."
        leaveRoom()
        if !wasTestMode { hostError = message }
        showToast(message)
    }

    /// Test Zone hosts a real room and joins a simulated friend to it, so the
    /// network, the player control and the menu bar icon all get exercised
    /// without needing a second person.
    func enterTestZone() {
        guard !hosting, !joining, !inRoom else { return }
        let operationID = UUID()
        roomOperationID = operationID
        hosting = true
        hostError = nil
        joinError = nil
        sync.startHosting { [weak self] result in
            guard let self, self.roomOperationID == operationID else { return }
            self.hosting = false
            switch result {
            case .failure(let error):
                self.sync.stop()
                self.roomOperationID = nil
                self.showToast("Couldn't start test mode: \(error.localizedDescription)")
            case .success:
                self.isTestMode = true
                self.roomTransport = .test
                self.inRoom = true
                self.disconnected = false
                self.statusLabel = "Test mode"
                self.startDetecting()
                // Prefer a player you already have open; otherwise use Sofa's own.
                self.playerChoice = self.detectedSources.first ?? .builtin
                self.applyPlayerChoice()
                if self.playerChoice == .builtin { self.builtin.loadDemo() }
                // The fake friend starts only after NWListener reached .ready
                // and Sofa's own client authenticated successfully.
                self.testFriend.join(token: self.sync.roomToken)
            }
        }
    }

    func leaveRoom() {
        roomOperationID = nil
        if theaterActive || theaterTransitioning { stopTheater() }
        FakeCall.shared.hide()
        testFriend.leave()
        sync.stop()
        PlayerBridge.shared.stop()
        builtin.reset()
        stopDetecting()
        inRoom = false
        isHosting = false
        isTestMode = false
        hosting = false
        joining = false
        hostError = nil
        joinError = nil
        roomTransport = nil
        inviteLink = ""
        inviteCode = ""
        joinAddress = ""
        peerCount = 0
        mediaActive = false
        extLive = .searching
        detectedSources = []
        unsupportedNotice = nil
        detectedCallApp = nil
        nowPlaying = nil
        nowPlayingPoster = nil
        nowPlayingURL = nil
        friendNowPlaying = nil
        friendNowPlayingArt = nil
        friendNowPlayingURL = nil
        friendPlaybackTime = nil
        friendIsPlaying = nil
        friends = []
    }

    // MARK: - Active source detection

    func startDetecting() {
        refreshSources()
        detectTimer?.invalidate()
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSources() }
        }
        timer.tolerance = 1.0
        detectTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        if workspaceObservers.isEmpty {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(center.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.refreshSources() }
                })
            }
        }
    }

    func stopDetecting() {
        detectTimer?.invalidate()
        detectTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        stopCallAudio()
        theaterAvailabilityProbeID = nil
        theaterAvailabilityChecking = false
        browserPageFullscreenReady = false
    }

    func refreshSources() {
        let runningIDs = MediaSourceDetector.runningBundleIDs()
        let running = MediaSourceDetector.runningPlayers(in: runningIDs)
        if running != detectedSources {
            detectedSources = running
            PlayerBridge.shared.wakePolling()
        }
        let notice = MediaSourceDetector.runningUnsupported(in: runningIDs).first?.advice
        if notice != unsupportedNotice { unsupportedNotice = notice }
        let call = WindowArranger.runningCallApp(in: runningIDs)
        if call?.bundleID != detectedCallApp?.bundleID {
            detectedCallApp = call
            if call?.bundleID == "com.apple.FaceTime", callVolume < 99.5 {
                scheduleCallVolume(callVolume)
            } else {
                stopCallAudioProcessor()
            }
        }
    }

    /// The normal player poll already runs while a room is active. Reusing its
    /// fullscreen bit avoids launching a second osascript process every few
    /// seconds solely for Theater availability.
    func playerBridgeReportedFullscreen(_ ready: Bool?, for player: PlayerChoice) {
        guard let ready, player == playerChoice, player.isBrowser,
              !theaterTransitioning else { return }
        if browserPageFullscreenReady != ready { browserPageFullscreenReady = ready }
        if theaterActive, !ready {
            stopTheater()
            showToast("The video left full screen, so Theater was closed.")
        }
    }

    func setCallVolume(_ value: Double) {
        callVolume = max(0, min(100, value))
        UserDefaults.standard.set(callVolume, forKey: "SofaFaceTimeVolume")
        scheduleCallVolume(callVolume)
    }

    func updateFriendPlayback(time: Double?, playing: Bool?, sentAt: Double?) {
        if let time {
            let networkAge = sentAt.map {
                min(2, max(0, Date().timeIntervalSince1970 - $0 / 1000))
            } ?? 0
            friendPlaybackTime = time + ((playing ?? friendIsPlaying) == true ? networkAge : 0)
            friendPlaybackUpdatedAt = Date()
        }
        if let playing { friendIsPlaying = playing }
    }

    var estimatedFriendPlaybackTime: Double? {
        guard let friendPlaybackTime else { return nil }
        return friendPlaybackTime + (friendIsPlaying == true
            ? Date().timeIntervalSince(friendPlaybackUpdatedAt) : 0)
    }

    var friendMatchesLocalMedia: Bool {
        if let local = nowPlayingURL, let remote = friendNowPlayingURL {
            return local == remote
        }
        guard friendNowPlayingURL == nil,
              let local = nowPlaying?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let remote = friendNowPlaying?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return !local.isEmpty && local == remote
    }

    func broadcastCurrentMedia() {
        guard let name = nowPlaying else { return }
        let playback: (Double, Bool)?
        if case .playing(let time, let isPlaying) = extLive {
            playback = (time, isPlaying)
        } else {
            playback = nil
        }
        sync.send(SyncMessage(
            type: "loaded",
            time: playback?.0,
            playing: playback?.1,
            name: name,
            art: nowPlayingPoster,
            url: nowPlayingURL
        ))
    }

    func joinFriendPlayback() {
        guard let urlString = friendNowPlayingURL, let url = URL(string: urlString) else {
            showToast("This source can’t be opened automatically. Open the same title first, then Sofa will sync it.")
            return
        }
        let browser: PlayerChoice
        if playerChoice.isBrowser {
            browser = playerChoice
        } else if detectedSources.contains(.safari) {
            browser = .safari
        } else if detectedSources.contains(.chrome) {
            browser = .chrome
        } else {
            browser = .safari
        }
        selectPlayer(browser)
        PlayerBridge.shared.openRemoteMedia(
            url: url,
            player: browser,
            time: estimatedFriendPlaybackTime ?? 0,
            playing: friendIsPlaying ?? false
        )
    }

    private func scheduleCallVolume(_ value: Double) {
        callVolumeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyCallVolume(value) }
        callVolumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func applyCallVolume(_ value: Double) {
        guard detectedCallApp?.bundleID == "com.apple.FaceTime" else {
            stopCallAudioProcessor()
            return
        }
        guard #available(macOS 14.2, *) else {
            callVolume = 100
            showToast("Independent FaceTime volume requires macOS 14.2 or later.")
            return
        }
        if value < 99.5,
           !UserDefaults.standard.bool(forKey: "SofaExplainedAudioCapture") {
            UserDefaults.standard.set(true, forKey: "SofaExplainedAudioCapture")
            showToast("Allow Sofa to capture system audio. FaceTime is processed locally and never recorded.")
        }
        CallAudioVolume.shared.set(percent: value) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.callVolume = 100
                    UserDefaults.standard.set(100.0, forKey: "SofaFaceTimeVolume")
                    self.showToast(error.localizedDescription)
                }
            }
        }
    }

    func stopCallAudio() {
        callVolumeWorkItem?.cancel()
        callVolumeWorkItem = nil
        stopCallAudioProcessor()
    }

    private func stopCallAudioProcessor() {
        if #available(macOS 14.2, *) { CallAudioVolume.shared.stop() }
    }

    /// Checks the selected browser tab without changing its fullscreen state.
    /// Safe to call whenever the Sofa panel opens or the source timer ticks.
    func refreshTheaterAvailability() {
        let selectedPlayer = playerChoice
        guard selectedPlayer.isBrowser, !theaterTransitioning else {
            theaterAvailabilityProbeID = nil
            theaterAvailabilityChecking = false
            if !theaterActive { browserPageFullscreenReady = false }
            return
        }

        let probeID = UUID()
        theaterAvailabilityProbeID = probeID
        theaterAvailabilityChecking = true
        PlayerBridge.shared.compatibleBrowserPageFullscreen(for: selectedPlayer) { [weak self] ready in
            guard let self, self.theaterAvailabilityProbeID == probeID,
                  self.playerChoice == selectedPlayer else { return }
            self.theaterAvailabilityChecking = false
            self.browserPageFullscreenReady = ready
            if self.theaterActive, !ready {
                self.stopTheater()
                self.showToast("The video left full screen, so Theater was closed.")
            }
        }
    }

    // MARK: - Window layout

    /// Whether the black-curtain theater layout is currently up.
    @Published var theaterActive = false

    /// True while Sofa is leaving fullscreen, waiting for the Space transition,
    /// and verifying the final window layout.
    @Published var theaterTransitioning = false
    /// Theater is intentionally gated by the fullscreen the viewer opened with
    /// F. This is refreshed while the party panel is active and rechecked on
    /// every entrance so a stale value can never trigger a different layout.
    @Published private(set) var browserPageFullscreenReady = false
    @Published private(set) var theaterAvailabilityChecking = false
    private var theaterRequestID: UUID?
    private var theaterPlayer: PlayerChoice?
    private var theaterAvailabilityProbeID: UUID?

    var canEnterTheater: Bool {
        theaterActive || (playerChoice.isBrowser && browserPageFullscreenReady)
    }

    /// Adds Sofa's call surface to the HTML fullscreen the viewer already opened
    /// with F. Browser Theater never exits that fullscreen and never creates a
    /// replacement Space of its own.
    func toggleTheater() {
        if theaterActive || theaterTransitioning {
            stopTheater()
            return
        }
        let selectedPlayer = playerChoice
        guard selectedPlayer.isBrowser else {
            showToast("Theater is available for fullscreen browser video.")
            return
        }
        guard WindowArranger.hasAccessibilityPermission else {
            WindowArranger.requestAccessibilityPermission()
            showToast("Allow Sofa in Accessibility, then press the button again.")
            return
        }
        let requestID = UUID()
        theaterRequestID = requestID
        theaterPlayer = selectedPlayer
        theaterTransitioning = true
        theaterAvailabilityProbeID = nil
        theaterAvailabilityChecking = true

        let markReady: () -> Void = { [weak self] in
            guard let self, self.theaterRequestID == requestID else { return }
            self.theaterTransitioning = false
            self.theaterActive = true
            self.browserPageFullscreenReady = true
            NotificationCenter.default.post(name: .sofaHidePanel, object: nil)
        }

        let failBeforeArrangement: (String) -> Void = { [weak self] message in
            guard let self, self.theaterRequestID == requestID else { return }
            self.theaterRequestID = nil
            self.theaterPlayer = nil
            self.theaterTransitioning = false
            self.theaterAvailabilityChecking = false
            self.showToast(message)
        }

        // Recheck at the click boundary. The periodically published value is UI
        // guidance only; it is never trusted to mutate a browser window.
        PlayerBridge.shared.compatibleBrowserPageFullscreen(for: selectedPlayer) { [weak self] pageFullscreen in
            guard let self, self.theaterRequestID == requestID else { return }
            self.theaterAvailabilityChecking = false
            self.browserPageFullscreenReady = pageFullscreen
            guard pageFullscreen else {
                failBeforeArrangement("Put the video in full screen first (press F), then enter Theater.")
                return
            }

            let call: WindowArranger.CallTarget
            let reserveCallColumn: Bool
            if FakeCall.shared.visible {
                call = .fake
                reserveCallColumn = true
            } else if !self.isTestMode, let real = self.detectedCallApp {
                call = .app(real)
                reserveCallColumn = true
            } else {
                // Test mode ignores unrelated call apps that merely happen to be
                // open. Use “Show fake call window” to populate the right side.
                call = .none
                reserveCallColumn = false
            }

            WindowArranger.enterTheater(
                player: selectedPlayer,
                call: call,
                useBrowserFullscreenStage: true,
                browserPageFullscreen: true
            ) { [weak self] result in
                guard let self, self.theaterRequestID == requestID else { return }
                switch result {
                case .failure(let error):
                    self.stopTheater()
                    self.showToast(error.localizedDescription)
                case .success:
                    // The site remains in its own fullscreen. Reserve the right
                    // side without reparenting YouTube or touching Netflix's DRM
                    // video/canvas/transform.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        guard let self, self.theaterRequestID == requestID else { return }
                        PlayerBridge.shared.setCinema(
                            true,
                            for: selectedPlayer,
                            reserveCallColumn: reserveCallColumn
                        ) { [weak self] cinemaReady in
                            guard let self, self.theaterRequestID == requestID else { return }
                            if !cinemaReady {
                                self.stopTheater()
                                self.showToast("Sofa couldn't prepare this YouTube or Netflix player. Keep the video tab visible and try again.")
                                return
                            }
                            // Confirm F is still active after the CSS landed. A
                            // successful Cinema result is also required to end in
                            // |pagefs, but this independent probe closes the race.
                            PlayerBridge.shared.compatibleBrowserPageFullscreen(for: selectedPlayer) { [weak self] stillFullscreen in
                                guard let self, self.theaterRequestID == requestID else { return }
                                guard stillFullscreen else {
                                    self.stopTheater()
                                    self.showToast("The video left full screen before Theater was ready.")
                                    return
                                }
                                markReady()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Idempotent cleanup for Exit, changing player, leaving the party and quit.
    func stopTheater() {
        theaterRequestID = nil
        theaterTransitioning = false
        theaterAvailabilityProbeID = nil
        theaterAvailabilityChecking = false
        if let player = theaterPlayer {
            PlayerBridge.shared.setCinema(false, for: player) { [weak self] removed in
                guard !removed else { return }
                // Retry the exact captured tab once without changing its
                // fullscreen state. Cleanup is idempotent.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    PlayerBridge.shared.setCinema(false, for: player) { retryRemoved in
                        if !retryRemoved {
                            self?.showToast("Sofa couldn't fully restore the browser tab. Reload that tab to clear Theater.")
                        }
                    }
                }
            }
        }
        WindowArranger.exitTheater()
        theaterActive = false
        theaterPlayer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshTheaterAvailability()
        }
    }

    /// Synchronous browser cleanup for `applicationWillTerminate`. Normal
    /// Theater exit remains asynchronous so the menu-bar UI never blocks.
    @discardableResult
    func prepareTheaterForTermination() -> Bool {
        let hadTheater = theaterActive || theaterTransitioning || theaterPlayer != nil
            || WindowArranger.restorationPending
        theaterRequestID = nil
        theaterTransitioning = false
        // Always serialize browser cleanup: the user may have pressed Exit a
        // fraction of a second before Quit, clearing `theaterPlayer` while the
        // precise tab cleanup was still waiting on PlayerBridge's queue.
        PlayerBridge.shared.clearCinemaBeforeTermination(for: theaterPlayer)
        WindowArranger.exitTheater()
        theaterActive = false
        theaterPlayer = nil
        return hadTheater
    }

    // MARK: - Player choice

    func selectPlayer(_ choice: PlayerChoice) {
        if theaterActive || theaterTransitioning { stopTheater() }
        theaterAvailabilityProbeID = nil
        theaterAvailabilityChecking = false
        browserPageFullscreenReady = false
        playerChoice = choice
        applyPlayerChoice()
    }

    func applyPlayerChoice() {
        theaterAvailabilityProbeID = nil
        theaterAvailabilityChecking = false
        browserPageFullscreenReady = false
        if playerChoice == .builtin {
            PlayerBridge.shared.stop()
        } else {
            builtin.pauseAndUnload()
            extLive = .searching
            nowPlaying = nil
            nowPlayingPoster = nil
            nowPlayingURL = nil
            mediaActive = true
            PlayerBridge.shared.start(player: playerChoice)
        }
        refreshTheaterAvailability()
    }
}

/// Best address to put in the invite link: prefer Tailscale/VPN, then LAN ranges.
func primaryIP() -> String {
    var ips: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "127.0.0.1" }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(ifa.ifa_flags)
        guard (flags & IFF_LOOPBACK) == 0, (flags & IFF_UP) != 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                       nil, 0, NI_NUMERICHOST) == 0 {
            ips.append(String(cString: host))
        }
    }
    return ips.first { $0.hasPrefix("100.") }
        ?? ips.first { $0.hasPrefix("192.168.") }
        ?? ips.first { $0.hasPrefix("10.") }
        ?? ips.first
        ?? "127.0.0.1"
}
