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
            if state.inRoom {
                RoomView()
            } else {
                IdleView()
            }
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
        VStack(spacing: 12) {
            Text("Watch movies together, apart.\nPlayback stays perfectly in sync.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)

            Button {
                state.hostRoom()
            } label: {
                Text("Start a Watch Party")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .sofaProminentButton()
            .controlSize(.large)

            HStack(spacing: 10) {
                Rectangle().fill(.separator).frame(height: 1)
                Text("or join a friend").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize()
                Rectangle().fill(.separator).frame(height: 1)
            }

            HStack(spacing: 8) {
                TextField("Paste an invite link or address", text: $state.joinAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.join() }
                Button("Join") { state.join() }
                    .sofaGlassButton()
                    .disabled(state.joining)
            }

            if let err = state.joinError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }

            Text("Got a **sofa://** link from iMessage? Just click it — Sofa joins automatically.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Test Zone") { state.enterTestZone() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
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
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }
}

struct InviteCard: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Card {
            SectionLabel(text: "Invite friends")
            Text(state.inviteLink)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 8) {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.inviteLink, forType: .string)
                    state.showToast("Invite link copied — paste it in iMessage")
                }
                .sofaGlassButton()
                .frame(maxWidth: .infinity)
                ShareButton(link: state.inviteLink)
                    .frame(maxWidth: .infinity)
            }
            Text("Same Wi-Fi works out of the box. On different networks, use Tailscale or forward port 7420.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
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
                    title: state.playerChoice == player ? state.nowPlaying : nil
                ) { state.selectPlayer(player) }
            }

            // The built-in player is always available.
            SourceRow(
                player: .builtin,
                selected: state.playerChoice == .builtin,
                live: nil,
                title: state.playerChoice == .builtin ? state.builtin.mediaName : nil
            ) { state.selectPlayer(.builtin) }

            // What the other side is watching, straight from their broadcast.
            if let friendTitle = state.friendNowPlaying {
                Divider().opacity(0.4)
                HStack(spacing: 8) {
                    Image(systemName: "sofa.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Your friend is watching")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text(friendTitle)
                            .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
            }

            if state.detectedSources.isEmpty {
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

            // Escape hatch: pick an app that isn't open yet.
            Menu {
                ForEach(PlayerChoice.externalPlayers) { p in
                    Button(p.shortLabel) { state.selectPlayer(p) }
                }
            } label: {
                Text("Choose an app that isn’t open yet")
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

/// A selectable source row: app icon + name + status, like Control Center.
struct SourceRow: View {
    let player: PlayerChoice
    let selected: Bool
    let live: ExtLiveState?
    /// What's actually playing in this app, when we know it.
    var title: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 28, height: 28)
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

    @ViewBuilder private var icon: some View {
        if player == .builtin {
            Image(systemName: "sofa.fill")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary).padding(4)
        } else if let ic = player.appIcon {
            Image(nsImage: ic).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "play.rectangle")
                .resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary).padding(2)
        }
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
