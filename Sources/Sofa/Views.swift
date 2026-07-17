import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Liquid Glass helpers (official APIs, with pre-macOS 26 fallbacks)

extension View {
    /// Prominent action button: Liquid Glass on macOS 26+, bordered before.
    @ViewBuilder func sofaProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Secondary button: Liquid Glass on macOS 26+, bordered before.
    @ViewBuilder func sofaGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Floating glass surface (toast, badges).
    @ViewBuilder func sofaGlassSurface(cornerRadius: CGFloat = 12) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            Group {
                if state.inRoom {
                    RoomView()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    IdleView()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.spring(duration: 0.35), value: state.inRoom)
        }
        // No minHeight: the panel measures this view and sizes itself to fit,
        // so there's never a slab of empty glass under the content.
        .frame(width: 380)
        .overlay(alignment: .bottom) {
            if let toast = state.toast {
                Text(toast)
                    .font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .sofaGlassSurface(cornerRadius: 10)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.toast)
    }
}

// MARK: - Title bar

struct TitleBar: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sofa.fill")
                .foregroundStyle(.secondary)
            Text("Sofa").font(.system(size: 13, weight: .semibold))

            if state.inRoom {
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.disconnected ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                    Text("\(state.statusLabel) \(state.peersText)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }

            Spacer()

            Menu {
                Text("Sofa \(Updater.shared.currentVersion)")
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                Divider()
                Button("Quit Sofa") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sofa options")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }
}

// MARK: - Idle

struct IdleView: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(spacing: 14) {
            // Hero
            VStack(spacing: 6) {
                Image(systemName: "sofa.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Color.accentColor.gradient)
                    .padding(.top, 2)
                Text("Movie nights, together — apart.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Play, pause and skip stay perfectly in sync\nwith everyone in your party.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 2)

            // Identity: quiet inline row, not a form field shouting for attention.
            HStack(spacing: 6) {
                AvatarView(name: state.displayName, size: 22)
                Text("Watching as")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Name", text: $state.displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: Capsule())

            Button {
                state.hostRoom()
            } label: {
                Label("Start a Watch Party", systemImage: "play.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .sofaProminentButton()
            .controlSize(.large)

            HStack(spacing: 10) {
                Rectangle().fill(.separator).frame(height: 1)
                Text("or join a friend").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize()
                Rectangle().fill(.separator).frame(height: 1)
            }

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Paste an invite link", text: $state.joinAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { state.join() }
                    Button("Join") { state.join() }
                        .sofaGlassButton()
                        .disabled(state.joining)
                }
                if let err = state.joinError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Or just click the **sofa://** link your friend sent — Sofa joins by itself.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                state.enterTestZone()
            } label: {
                Label("Try it solo — Test Zone", systemImage: "testtube.2")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(.horizontal, 18).padding(.bottom, 14)
    }
}

/// Initials-in-a-circle avatar, tinted deterministically from the name.
struct AvatarView: View {
    let name: String
    var size: CGFloat = 24

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]

    var body: some View {
        let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        let tint = Self.palette[abs(name.hashValue) % Self.palette.count]
        Circle()
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(letter.isEmpty ? "?" : letter)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Room

struct RoomView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var builtin = AppState.shared.builtin

    var body: some View {
        // A plain stack rather than a ScrollView: the panel measures this and
        // sizes itself to fit, so it's exactly as tall as the content needs.
        VStack(spacing: 10) {
            if state.isHosting && !state.inviteLink.isEmpty {
                InviteCard()
            }
            if state.isTestMode {
                TestFriendCard()
            }
            PlayerCard()
            if state.playerChoice == .builtin {
                BuiltinStage()
            }
            LayoutCard()
            AudioCard()

            Button("Leave Watch Party") {
                state.leaveRoom()
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.red)
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 4)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.35)))
    }
}

struct InviteCard: View {
    @ObservedObject var state = AppState.shared

    /// The 6-char room code, pulled from the tail of the invite link.
    private var roomCode: String {
        state.inviteLink.split(separator: "/").last.map(String.init) ?? ""
    }

    var body: some View {
        Card {
            HStack {
                SectionLabel(text: "Your party")
                Spacer()
                // Everyone here, as avatars — you first.
                HStack(spacing: -6) {
                    AvatarView(name: state.displayName, size: 22)
                    ForEach(state.friends) { friend in
                        AvatarView(name: friend.name, size: 22)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    }
                }
                .help(state.friends.isEmpty
                      ? "Just you so far"
                      : "You, " + state.friends.map(\.name).joined(separator: ", "))
            }

            if state.friends.isEmpty {
                Text("Waiting for friends — send them the invite:")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("Here with " + state.friends.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            // The room code is the star; the raw link stays behind Copy/Share.
            HStack(spacing: 3) {
                ForEach(Array(roomCode.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .frame(width: 26, height: 32)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                Spacer(minLength: 8)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.inviteLink, forType: .string)
                    state.showToast("Invite link copied — paste it in iMessage")
                }
                .sofaGlassButton()
                ShareButton(link: state.inviteLink)
            }

            Text("Only people with this link can join. Same Wi-Fi just works; across networks, use Tailscale or forward port 7420.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
}

/// Native share sheet (Messages, Mail, AirDrop…) anchored to the button.
struct ShareButton: NSViewRepresentable {
    let link: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Share…", target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        context.coordinator.link = link
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.link = link
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSSharingServicePickerDelegate {
        var link = ""
        @objc func share(_ sender: NSButton) {
            guard let url = URL(string: link) else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

struct PlayerCard: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Card {
            SectionLabel(text: "Play from")

            // Active sources detected right now (like Control Center's Now Playing).
            ForEach(state.detectedSources) { player in
                SourceRow(
                    player: player,
                    selected: state.playerChoice == player,
                    live: state.playerChoice == player ? state.extLive : nil,
                    title: state.playerChoice == player ? state.nowPlaying : nil,
                    poster: state.playerChoice == player ? state.nowPlayingPoster : nil
                ) { state.selectPlayer(player) }
            }

            // Built-in player only appears as a row while it's the one in use
            // (eg. Test Zone); otherwise it lives in the overflow menu below.
            if state.playerChoice == .builtin {
                SourceRow(
                    player: .builtin,
                    selected: true,
                    live: nil,
                    title: state.builtin.mediaName,
                    poster: nil
                ) { }
            }

            // What the other side is watching, straight from their broadcast.
            if let friendTitle = state.friendNowPlaying {
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    RemoteImage(
                        urlString: state.friendNowPlayingArt,
                        fallback: NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: nil)
                    )
                    .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your friend is watching")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(friendTitle)
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }

            if state.detectedSources.isEmpty && state.playerChoice != .builtin {
                Text("Open a movie in QuickTime, VLC, Apple TV or your browser (YouTube, Netflix, Prime Video…) and it’ll show up here.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }

            if let notice = state.unsupportedNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            // Escape hatch: pick an app that isn't open yet, or Sofa's own player.
            Menu {
                ForEach(PlayerChoice.externalPlayers) { p in
                    Button(p.shortLabel) { state.selectPlayer(p) }
                }
                Divider()
                Button("Sofa’s built-in player") { state.selectPlayer(.builtin) }
            } label: {
                Text("Choose another player…")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.top, 2)

            // Setup hint + detailed live status for the selected external player.
            if state.playerChoice != .builtin {
                Divider().opacity(0.4)
                Text(state.playerChoice.hint)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                if liveIsWarning {
                    Text(liveText)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var liveText: String {
        switch state.extLive {
        case .searching:
            return "Looking for something playing…"
        case .nothingOpen:
            return "Nothing open yet — start your video and it appears here."
        case .blocked(let browser):
            return browser == .safari
                ? "⚠️ Safari is blocking Sofa. Enable: Safari Settings → Advanced → “Show features for web developers”, then Developer tab → “Allow JavaScript from Apple Events”."
                : "⚠️ Chrome is blocking Sofa. Enable: View → Developer → Allow JavaScript from Apple Events."
        case .notAuthorized:
            return "⚠️ macOS denied automation. Fix it in System Settings → Privacy & Security → Automation → Sofa."
        case .playing(let time, let isPlaying):
            return "\(isPlaying ? "▶" : "⏸")  \(Self.fmt(time)) · \(isPlaying ? "playing" : "paused") — synced"
        }
    }

    private var liveIsWarning: Bool {
        if case .blocked = state.extLive { return true }
        if case .notAuthorized = state.extLive { return true }
        return false
    }

    static func fmt(_ t: Double) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// A fixed-size, aspect-filled, rounded thumbnail — like Control Center's.
/// Draws into its layer so it crops-to-fill and, crucially, reports no
/// intrinsic size, so the SwiftUI `.frame(28×28)` governs instead of the
/// image's own (huge) dimensions.
final class ArtworkView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.cornerRadius = 6
        layer.contentsScale = 2
        return layer
    }
    var picture: NSImage? {
        didSet {
            layer?.contents = picture?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }
}

/// Downloads and caches a remote image (poster / cover art), showing a fallback
/// image while it loads or if there's none. Built on AppKit (no SwiftUI @State,
/// whose macro plugin isn't in the command-line toolchain). Cached by URL so
/// the 0.7s poll doesn't re-download the same artwork.
struct RemoteImage: NSViewRepresentable {
    let urlString: String?
    let fallback: NSImage?

    func makeNSView(context: Context) -> ArtworkView {
        let view = ArtworkView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: ArtworkView, context: Context) {
        context.coordinator.load(urlString, fallback: fallback, into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var currentURL: String?

        func load(_ urlString: String?, fallback: NSImage?, into view: ArtworkView) {
            guard urlString != currentURL else { return }
            currentURL = urlString
            view.picture = fallback

            guard let urlString, let url = URL(string: urlString) else { return }
            if let cached = RemoteImageCache.shared.object(forKey: urlString as NSString) {
                view.picture = cached
                return
            }
            URLSession.shared.dataTask(with: url) { [weak view] data, _, _ in
                guard let data, let img = NSImage(data: data) else { return }
                RemoteImageCache.shared.setObject(img, forKey: urlString as NSString)
                DispatchQueue.main.async {
                    // Ignore if the row moved on to different content meanwhile.
                    guard self.currentURL == urlString else { return }
                    view?.picture = img
                }
            }.resume()
        }
    }
}

enum RemoteImageCache {
    static let shared: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 40
        return c
    }()
}

/// A selectable source row: app icon + name + status, like Control Center.
struct SourceRow: View {
    let player: PlayerChoice
    let selected: Bool
    let live: ExtLiveState?
    /// What's actually playing in this app, when we know it.
    var title: String?
    /// Content preview URL (og:image / cover art), shown instead of the app icon.
    var poster: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Content preview like Control Center, falling back to the app icon.
                RemoteImage(urlString: poster, fallback: fallbackImage)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    // Now Playing style: the title leads, the app is metadata.
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Text("\(player.shortLabel) · \(statusText)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(statusIsWarning ? .orange : .secondary)
                            .lineLimit(1)
                    } else {
                        Text(player.shortLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(statusText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(statusIsWarning ? .orange : .secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .background(
                selected ? Color.accentColor.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The app icon (or a symbol) shown when there's no content preview.
    private var fallbackImage: NSImage? {
        if player == .builtin {
            return NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: nil)
        }
        return player.appIcon
            ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
    }

    private var statusText: String {
        if let live {
            switch live {
            case .searching: return "Connecting…"
            case .nothingOpen: return "Open a video to start"
            case .blocked: return "Needs permission — tap for setup"
            case .notAuthorized: return "Automation blocked — tap for setup"
            case .playing(let t, let playing):
                return "\(playing ? "▶" : "⏸") \(PlayerCard.fmt(t)) · synced"
            }
        }
        if player == .builtin { return "Play a file inside Sofa" }
        return "Running · tap to sync"
    }

    private var statusIsWarning: Bool {
        if case .blocked = live { return true }
        if case .notAuthorized = live { return true }
        return false
    }
}

/// AppKit's AVPlayerView rather than SwiftUI's `VideoPlayer`: the latter's
/// _AVKit_SwiftUI overlay fails to build its generic metadata at runtime here
/// and aborts the process (EXC_CRASH in getSuperclassMetadata) the moment a
/// video is shown.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct BuiltinStage: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var builtin = AppState.shared.builtin

    var body: some View {
        Group {
            if builtin.hasMedia {
                PlayerView(player: builtin.player)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 10) {
                    Text("Drop a movie or song here")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.75))
                    HStack(spacing: 8) {
                        Button("Open File…") { openFile() }.sofaGlassButton()
                        Button("Test Video") { state.builtin.loadDemo() }.sofaGlassButton()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url {
                            DispatchQueue.main.async { state.builtin.load(url: url) }
                        }
                    }
                    return true
                }
            }
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a movie or song"
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .mp3]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.builtin.load(url: url)
        }
    }
}

/// Test Zone's fake second person: press these and your real player should
/// obey, exactly as if a friend on another Mac had pressed them.
struct TestFriendCard: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var friend = AppState.shared.testFriend

    var body: some View {
        Card {
            HStack(spacing: 6) {
                SectionLabel(text: "Simulated friend")
                Circle()
                    .fill(friend.connected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
            Text(friend.connected
                 ? "Press these as if your friend did — your \(state.playerChoice.shortLabel) should follow."
                 : "Connecting the simulated friend…")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button("▶ Play") { friend.pressPlay() }.sofaGlassButton()
                Button("⏸ Pause") { friend.pressPause() }.sofaGlassButton()
            }
            HStack(spacing: 6) {
                Button("↩ Back 15s") { friend.skip(by: -15) }.sofaGlassButton()
                Button("↪ Skip 30s") { friend.skip(by: 30) }.sofaGlassButton()
            }
            .disabled(!friend.connected)

            Text("The menu bar icon turns into a 2-seat sofa while the friend is in the room.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(friend.connected ? 1 : 0.7)
    }
}

/// One-click window layout: movie left, video call right, nothing overlapping.
struct LayoutCard: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Card {
            SectionLabel(text: "On a call?")
            HStack(spacing: 10) {
                LayoutDiagram()
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(subline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button("Arrange Windows") { state.arrangeWindows() }
                .sofaGlassButton()
                .disabled(state.detectedCallApp == nil || state.playerChoice == .builtin)
        }
    }

    private var headline: String {
        if let call = state.detectedCallApp {
            return "\(call.name) call detected"
        }
        return "No call detected"
    }

    private var subline: String {
        if state.playerChoice == .builtin {
            return "Arranging needs an external player like QuickTime or your browser."
        }
        if state.detectedCallApp != nil {
            return "Puts your movie on the left, as big as it fits, and the call in a column on the right — no overlap."
        }
        return "Start a FaceTime, Zoom, Discord, Teams or WhatsApp call and Sofa can lay the windows out for you."
    }
}

/// Tiny picture of what Arrange does: wide video left, small call right.
struct LayoutDiagram: View {
    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 30, height: 26)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.25))
                .frame(width: 9, height: 14)
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct AudioCard: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Card {
            SectionLabel(text: "Audio")
            if state.playerChoice == .builtin {
                SliderRow(label: "Movie", value: $state.movieVolume, range: 0...100, suffix: "%") { v in
                    state.builtin.volume = Float(v / 100)
                }
            }
            SliderRow(label: "Mac", value: $state.systemVolume, range: 0...100, suffix: "%") { v in
                SystemVolume.set(Int(v))
            }
            Text("On a call? Lower the Mac volume — the movie player’s own volume stays independent.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: $value, in: range) { _ in
                onChange(value)
            }
            .onChange(of: value) { _, v in onChange(v) }
            Text("\(Int(value))\(suffix)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }
}
