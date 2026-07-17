import AppKit
import Combine
import Foundation

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
    @MainActor var appIcon: NSImage? {
        guard let bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Players Sofa can drive (excludes the built-in player).
    static var externalPlayers: [PlayerChoice] {
        [.quicktime, .vlc, .appleTV, .chrome, .safari, .music, .spotify]
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

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Room
    @Published var inRoom = false
    @Published var isHosting = false
    @Published var isTestMode = false
    @Published var statusLabel = ""
    @Published var peerCount = 0
    @Published var disconnected = false
    @Published var inviteLink = ""
    @Published var joinAddress = ""
    @Published var joinError: String?
    @Published var joining = false

    // Player
    @Published var playerChoice: PlayerChoice = .quicktime
    @Published var extLive: ExtLiveState = .searching
    /// What's playing here, and what our friend says is playing on their side.
    @Published var nowPlaying: String?
    @Published var nowPlayingPoster: String?
    @Published var friendNowPlaying: String?
    @Published var friendNowPlayingArt: String?

    // Auto-detected active players (running apps), refreshed while in a room.
    @Published var detectedSources: [PlayerChoice] = []
    /// Running media apps that can't be automated (shown as an explanation).
    @Published var unsupportedNotice: String?
    /// The video-call app currently running, if any (for the Arrange layout).
    @Published var detectedCallApp: WindowArranger.CallApp?
    private var detectTimer: Timer?

    // Audio
    @Published var systemVolume: Double = 50
    @Published var movieVolume: Double = 100

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

    func showToast(_ text: String) {
        toast = text
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.toast = nil }
        }
    }

    var peersText: String {
        let others = max(0, peerCount - 1)
        if isTestMode { return others > 0 ? "· simulated friend" : "· connecting…" }
        if others == 0 { return "· waiting…" }
        return "· \(others) friend\(others > 1 ? "s" : "")"
    }

    // MARK: - Room lifecycle

    func hostRoom() {
        do {
            try sync.startHosting()
            let ip = primaryIP()
            inviteLink = "sofa://join/\(ip):\(SyncEngine.port)"
            isHosting = true
            enterRoom(label: "Hosting")
        } catch {
            showToast("Could not start the party: \(error.localizedDescription)")
        }
    }

    func join(target: String? = nil) {
        let raw = target ?? joinAddress
        let addr = Self.parseTarget(raw)
        guard !addr.isEmpty else { return }
        joinError = nil
        joining = true
        sync.connect(to: addr) { [weak self] ok in
            guard let self else { return }
            self.joining = false
            if ok {
                self.enterRoom(label: "Connected")
            } else {
                self.joinError = "Could not connect. Check the link or address and try again."
            }
        }
    }

    /// Accept a raw address, a sofa:// link, or anything containing one.
    static func parseTarget(_ text: String) -> String {
        if let r = text.range(of: #"sofa://join/([^\s/]+)"#, options: .regularExpression) {
            return String(text[r]).replacingOccurrences(of: "sofa://join/", with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Test Zone hosts a real room and joins a simulated friend to it, so the
    /// network, the player control and the menu bar icon all get exercised
    /// without needing a second person.
    func enterTestZone() {
        do {
            try sync.startHosting()
        } catch {
            showToast("Couldn't start test mode: \(error.localizedDescription)")
            return
        }
        isTestMode = true
        inRoom = true
        disconnected = false
        statusLabel = "Test mode"
        startDetecting()
        // Prefer a player you already have open; otherwise use Sofa's own.
        playerChoice = detectedSources.first ?? .builtin
        applyPlayerChoice()
        if playerChoice == .builtin { builtin.loadDemo() }
        testFriend.join()
    }

    func leaveRoom() {
        testFriend.leave()
        sync.stop()
        PlayerBridge.shared.stop()
        builtin.reset()
        stopDetecting()
        inRoom = false
        isHosting = false
        isTestMode = false
        inviteLink = ""
        joinAddress = ""
        peerCount = 0
        mediaActive = false
        extLive = .searching
        detectedSources = []
        unsupportedNotice = nil
        detectedCallApp = nil
        nowPlaying = nil
        nowPlayingPoster = nil
        friendNowPlaying = nil
        friendNowPlayingArt = nil
    }

    // MARK: - Active source detection

    func startDetecting() {
        refreshSources()
        detectTimer?.invalidate()
        detectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSources() }
        }
    }

    func stopDetecting() {
        detectTimer?.invalidate()
        detectTimer = nil
    }

    func refreshSources() {
        let running = MediaSourceDetector.runningPlayers()
        if running != detectedSources { detectedSources = running }
        let notice = MediaSourceDetector.runningUnsupported().first?.advice
        if notice != unsupportedNotice { unsupportedNotice = notice }
        let call = WindowArranger.runningCallApp()
        if call?.bundleID != detectedCallApp?.bundleID { detectedCallApp = call }
    }

    // MARK: - Window layout

    /// Arranges the movie and the call side by side, prompting for the
    /// Accessibility permission the first time.
    func arrangeWindows() {
        guard let call = detectedCallApp else {
            showToast("No video call found — start your FaceTime call first.")
            return
        }
        guard playerChoice != .builtin else {
            showToast("Arranging works with an external player, not Sofa’s own.")
            return
        }
        guard WindowArranger.hasAccessibilityPermission else {
            WindowArranger.requestAccessibilityPermission()
            showToast("Allow Sofa in Accessibility, then press Arrange again.")
            return
        }
        do {
            try WindowArranger.arrange(player: playerChoice, callApp: call)
            showToast("Arranged: \(playerChoice.shortLabel) left, \(call.name) right.")
        } catch {
            showToast(error.localizedDescription)
        }
    }

    // MARK: - Player choice

    func selectPlayer(_ choice: PlayerChoice) {
        playerChoice = choice
        applyPlayerChoice()
    }

    func applyPlayerChoice() {
        if playerChoice == .builtin {
            PlayerBridge.shared.stop()
        } else {
            builtin.pauseAndUnload()
            extLive = .searching
            nowPlaying = nil
            nowPlayingPoster = nil
            mediaActive = true
            PlayerBridge.shared.start(player: playerChoice)
        }
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
