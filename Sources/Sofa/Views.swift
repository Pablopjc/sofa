import AVKit
import AppKit
import ImageIO
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
    @ObservedObject var social = SocialService.shared

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            if let invite = social.invitations.first {
                PartyInvitationCard(invite: invite)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Group {
                if !state.welcomeDone && !state.inRoom {
                    WelcomeView()
                        .transition(.opacity)
                } else if state.inRoom {
                    RoomView()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    IdleView()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .animation(.spring(duration: 0.35), value: state.inRoom)
            .animation(.spring(duration: 0.35), value: state.welcomeDone)
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
                Button("Help & Website") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Pablopjc/sofa#readme")!)
                }
                Button("Report a Problem") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Pablopjc/sofa/issues")!)
                }
                Button("Welcome Tour") {
                    UserDefaults.standard.set(false, forKey: "SofaWelcomeDone")
                    AppState.shared.welcomeDone = false
                }
                Divider()
                Button("Try it solo — Test Zone") { state.enterTestZone() }
                    .disabled(state.inRoom || state.hosting || state.joining)
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

/// First-run tour: what Sofa does and which permissions it will ask for, so
/// none of the system dialogs come as a surprise to a stranger.
struct WelcomeView: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sofa.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor.gradient)
            Text("Welcome to Sofa")
                .font(.system(size: 16, weight: .semibold))
            Text("Watch movies and shows with friends, perfectly in sync — each of you on your own Mac, with your own accounts.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                WelcomeRow(icon: "play.circle.fill",
                           title: "Works with what you already use",
                           text: "QuickTime, VLC, Apple TV, and YouTube, Netflix or Prime Video in Safari and Chrome.")
                WelcomeRow(icon: "link",
                           title: "One link to watch together",
                           text: "Start a party, send the invite link — friends click it and playback stays in sync, even in different countries.")
                WelcomeRow(icon: "hand.raised.fill",
                           title: "About the permission prompts",
                           text: "macOS will ask you to allow Sofa to control your video player (that's how sync works) and, for Theater mode, to arrange windows. Sofa never sees or transmits your video or audio.")
            }
            .padding(14)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

            Button {
                state.welcomeDone = true
            } label: {
                Text("Get Started")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .sofaProminentButton()
            .controlSize(.large)
        }
        .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 4)
    }
}

struct WelcomeRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct IdleView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var social = SocialService.shared

    private static let maximumDisplayNameLength = 40

    private var displayName: Binding<String> {
        Binding(
            get: { state.displayName },
            set: { value in
                let disallowed = CharacterSet.controlCharacters.union(.newlines)
                let singleLine = value.components(separatedBy: disallowed).joined(separator: " ")
                state.displayName = singleLine
                    .prefix(Self.maximumDisplayNameLength)
                    .description
            }
        )
    }

    private func normalizeDisplayName() {
        let normalized = state.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        state.displayName = normalized.isEmpty ? "Me" : normalized
    }

    var body: some View {
        VStack(spacing: 9) {
            // Hero
            VStack(spacing: 4) {
                Image(systemName: "sofa.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(Color.accentColor.gradient)
                Text("Movie nights, together — apart.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Play, pause and skip stay perfectly in sync\nwith everyone in your party.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            // You on the left, your people on the right — one compact strip
            // instead of a floating name pill plus a separate explainer card.
            IdentityFriendsRow(displayName: displayName, normalize: normalizeDisplayName)

            Button {
                normalizeDisplayName()
                state.hostRoom()
            } label: {
                HStack(spacing: 7) {
                    if state.hosting {
                        ProgressView().controlSize(.small)
                        Text("Creating online party…")
                    } else {
                        Image(systemName: "play.circle.fill")
                        Text("Start a Watch Party")
                    }
                }
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .sofaProminentButton()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(state.hosting || state.joining)

            if let err = state.hostError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                        .onSubmit {
                            normalizeDisplayName()
                            state.join()
                        }
                        .disabled(state.hosting || state.joining)
                    Button("Join") {
                        normalizeDisplayName()
                        state.join()
                    }
                        .sofaGlassButton()
                        .buttonBorderShape(.capsule)
                        .disabled(state.hosting || state.joining)
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
    @ObservedObject var social = SocialService.shared

    /// The visible room ID is never the long capability secret in the link.
    private var roomCode: String {
        state.inviteCode
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
            // Smaller boxes + fixedSize buttons so "Copy Link" never truncates.
            HStack(spacing: 3) {
                ForEach(Array(roomCode.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .frame(width: 22, height: 28)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                }
                Spacer(minLength: 8)
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.inviteLink, forType: .string)
                    state.showToast("Invite link copied — paste it in iMessage")
                }
                .sofaGlassButton()
                .fixedSize()
                ShareButton(link: state.inviteLink)
            }

            Text(state.roomIsOnline
                 ? "Works across networks. Sofa relays only sync controls — never video or call audio."
                 : "Local party: friends must be on the same local network.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if state.roomIsOnline && !social.friends.isEmpty {
                Divider().opacity(0.4)
                HStack {
                    Text("Invite a saved friend")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Invite…") {
                        ForEach(social.friends) { friend in
                            Button(friend.name) { social.sendInvitation(to: friend) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}

/// One strip: your identity on the left, your saved friends on the right.
/// Replaces the old floating "Watching as" pill (mostly empty space) and the
/// separate FRIENDS explainer card that used to sit above the main action.
struct IdentityFriendsRow: View {
    let displayName: Binding<String>
    let normalize: () -> Void

    @ObservedObject var state = AppState.shared
    @ObservedObject var social = SocialService.shared

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                // You: avatar + editable name, sized to its content.
                AvatarView(name: state.displayName, size: 24)
                TextField("Your name", text: displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(minWidth: 40, maxWidth: 130)
                    .fixedSize(horizontal: true, vertical: false)
                    .onSubmit { normalize() }
                    .help("The name friends see in your parties")

                // A small, fixed gap — not a Spacer — so the name and the
                // friends/add control stay snug instead of stretching apart.
                if social.ready {
                    Divider().frame(height: 16).opacity(0.5)
                }

                // Your people: overlapping avatars + add button, like the
                // party card uses in-room.
                if social.ready && !social.friends.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(social.friends.prefix(4)) { friend in
                            AvatarView(name: friend.name, size: 22)
                                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                                .help(friend.name + (friend.online ? " · online" : ""))
                        }
                    }
                    if social.friends.count > 4 {
                        Text("+\(social.friends.count - 4)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }

                if social.ready {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(social.friendLink, forType: .string)
                        AppState.shared.showToast("Friend link copied — send it once; invitations then arrive right in Sofa.")
                    } label: {
                        if social.friends.isEmpty {
                            Label("Add a friend", systemImage: "person.badge.plus")
                                .font(.system(size: 11))
                        } else {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 11.5))
                        }
                    }
                    .sofaGlassButton()
                    .buttonBorderShape(.capsule)
                    .disabled(social.friendLink.isEmpty)
                    .help("Copy your friend link — friends who add it can invite you directly")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            // Horizontal inset matches the visual top/bottom gap around the
            // avatar and the Add-a-friend capsule, so the ring of space
            // inside the pill reads even all the way around.
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: Capsule())

            if let error = social.errorMessage {
                Text(error)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct PartyInvitationCard: View {
    let invite: SofaPartyInvitation
    @ObservedObject var state = AppState.shared
    @ObservedObject var social = SocialService.shared

    var body: some View {
        HStack(spacing: 9) {
            AvatarView(name: invite.fromName, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(invite.fromName) invited you")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(invite.title.map { "Watch “\($0)” together?" } ?? "Join their watch party?")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Not now") { social.dismissInvitation(id: invite.id) }
                .sofaGlassButton()
            Button("Join") { social.acceptInvitation(id: invite.id) }
                .sofaProminentButton()
                .disabled(state.inRoom || state.hosting || state.joining)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor.opacity(0.25)))
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
                    poster: state.playerChoice == player ? state.nowPlayingPoster : nil,
                    together: state.playerChoice == player && state.friendMatchesLocalMedia
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
            if let friendTitle = state.friendNowPlaying, !state.friendMatchesLocalMedia {
                Divider().opacity(0.4)
                Button { state.joinFriendPlayback() } label: {
                    HStack(spacing: 8) {
                        RemoteImage(
                            urlString: state.friendNowPlayingArt,
                            fallback: NSImage(systemSymbolName: "sofa.fill", accessibilityDescription: nil)
                        )
                        .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(friendTitle)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1).truncationMode(.tail)
                            if state.friendIsPlaying == true {
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    Text(friendPlaybackText)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            } else {
                                Text(friendPlaybackText)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 7)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if state.detectedSources.isEmpty && state.playerChoice != .builtin {
                Text("Open a movie in QuickTime, VLC, Apple TV or your browser (YouTube, Netflix, Prime Video…) and it’ll show up here.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .fixedSize(horizontal: false, vertical: true)
                if liveIsWarning {
                    Text(liveText)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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

    private var friendPlaybackText: String {
        let time = state.estimatedFriendPlaybackTime.map(Self.fmt) ?? "--:--"
        let status = state.friendIsPlaying == true ? "▶" : "⏸"
        return "Your friend · \(status) \(time) · tap to watch together"
    }

    private var liveIsWarning: Bool {
        if case .blocked = state.extLive { return true }
        if case .notAuthorized = state.extLive { return true }
        return false
    }

    static func fmt(_ t: Double) -> String {
        guard t.isFinite else { return "–:––" }
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
/// the player poll doesn't re-download the same artwork.
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
        private var task: URLSessionDataTask?

        func load(_ urlString: String?, fallback: NSImage?, into view: ArtworkView) {
            guard urlString != currentURL else { return }
            task?.cancel()
            task = nil
            currentURL = urlString
            view.picture = fallback

            guard let urlString, let url = URL(string: urlString) else { return }
            if let cached = RemoteImageCache.shared.object(forKey: urlString as NSString) {
                view.picture = cached
                return
            }
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 12
            task = URLSession.shared.dataTask(with: request) { [weak self, weak view] data, response, _ in
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      http.mimeType?.lowercased().hasPrefix("image/") == true,
                      http.expectedContentLength <= 8_000_000 || http.expectedContentLength < 0,
                      let data, data.count <= 8_000_000,
                      let img = Self.thumbnail(from: data) else { return }
                RemoteImageCache.shared.setObject(
                    img, forKey: urlString as NSString, cost: 128 * 128 * 4
                )
                DispatchQueue.main.async {
                    // Ignore if the row moved on to different content meanwhile.
                    guard self?.currentURL == urlString else { return }
                    view?.picture = img
                }
            }
            task?.resume()
        }

        /// Posters can be several thousand pixels wide. Sofa displays them at
        /// 28×28 points, so decoding and caching the original wastes tens of MB
        /// on both architectures (and is especially costly on older Intel GPUs).
        private static func thumbnail(from data: Data) -> NSImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: 64, height: 64))
        }
    }
}

enum RemoteImageCache {
    static let shared: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 40
        c.totalCostLimit = 8 * 1_024 * 1_024
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
    /// The remote peer reported this same canonical content URL.
    var together = false
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
                let prefix = together ? "Together · " : ""
                return "\(prefix)\(playing ? "▶" : "⏸") \(PlayerCard.fmt(t)) · synced"
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
    @ObservedObject var fakeCall = FakeCall.shared

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

            Button {
                FakeCall.shared.toggle()
            } label: {
                Label(fakeCall.visible ? "Hide fake call window" : "Show fake call window",
                      systemImage: "video.badge.checkmark")
                    .font(.system(size: 11.5))
            }
            .sofaGlassButton()

            Text("The menu bar icon turns into a 2-seat sofa while the friend is in the room.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(friend.connected ? 1 : 0.7)
    }
}

/// Theater mode: black curtain, movie as big as it fits, call in a right column.
struct LayoutCard: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        Card {
            SectionLabel(text: "Theater")
            HStack(spacing: 10) {
                TheaterDiagram()
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
            Button(theaterButtonTitle) {
                state.toggleTheater()
            }
            .sofaGlassButton()
            .disabled(state.theaterTransitioning || (!state.theaterActive && !state.canEnterTheater))
        }
    }

    @ObservedObject private var fakeCall = FakeCall.shared

    private var theaterButtonTitle: String {
        if state.theaterTransitioning { return "Preparing Theater…" }
        return state.theaterActive ? "Exit Theater" : "Enter Theater"
    }

    private var headline: String {
        if state.theaterTransitioning { return "Preparing the fullscreen overlay…" }
        if state.theaterActive { return "Theater is on" }
        if !state.playerChoice.isBrowser { return "Open a browser video first" }
        if state.browserPageFullscreenReady {
            return fakeCall.visible ? "Fullscreen and test call ready" : "Video fullscreen detected"
        }
        return "Press F in the video first"
    }

    private var subline: String {
        if state.theaterTransitioning {
            return "Keeping the fullscreen you opened and placing the call beside the video."
        }
        if state.theaterActive {
            return "Drag the edge between the video and black column to resize it. Exit Theater keeps the fullscreen opened with F."
        }
        if !state.playerChoice.isBrowser {
            return "Choose Safari or Chrome, open YouTube or Netflix, and put the video in full screen."
        }
        if !state.browserPageFullscreenReady {
            return "In the video, press F (or its fullscreen button). Then open Sofa again — Theater will become available."
        }
        if fakeCall.visible {
            return "Keeps that exact fullscreen, reserves the right side, and floats a compact call there."
        }
        return "Fullscreen is ready. Show the test call window if you want it on the right, then enter Theater."
    }
}

/// Tiny picture of Theater: black stage, wide movie, small call column.
struct TheaterDiagram: View {
    var body: some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.8))
                .frame(width: 30, height: 26)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.35))
                .frame(width: 9, height: 14)
        }
        .padding(4)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 5))
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
            if state.detectedCallApp?.bundleID == "com.apple.FaceTime" {
                SliderRow(label: "Call", value: $state.callVolume, range: 0...100, suffix: "%") { v in
                    state.setCallVolume(v)
                }
            }
            SliderRow(label: "Mac", value: $state.systemVolume, range: 0...100, suffix: "%") { v in
                SystemVolume.set(Int(v))
            }
            Text(state.detectedCallApp?.bundleID == "com.apple.FaceTime"
                 ? "Call changes only FaceTime. Audio is processed locally and is never saved or sent."
                 : "Start a FaceTime call to control its volume independently from the movie.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
