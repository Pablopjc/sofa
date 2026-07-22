import AppKit
import Foundation
import Security
import UserNotifications

struct SavedSofaFriend: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var online: Bool
}

struct SofaPartyInvitation: Codable, Identifiable, Equatable {
    let id: String
    let fromID: String
    let fromName: String
    let roomID: String
    let secret: String
    let title: String?
    let createdAt: Double
    let expiresAt: Double

    var joinURL: String { "sofa://join/v1/\(roomID)/\(secret)" }
}

@MainActor
final class SocialService: ObservableObject {
    static let shared = SocialService()
    static let notificationCategory = "SOFA_PARTY_INVITE"
    static let joinAction = "SOFA_JOIN_PARTY"
    static let declineAction = "SOFA_DECLINE_PARTY"

    @Published private(set) var friends: [SavedSofaFriend] = []
    @Published private(set) var friendLink = ""
    @Published private(set) var invitations: [SofaPartyInvitation] = []
    @Published private(set) var ready = false
    @Published var errorMessage: String?
    /// Friends already invited to the current party (shown as ✓ chips).
    @Published private(set) var invitedFriendIDs: Set<String> = []

    /// Dev-only fake friends (⋯ menu) so the whole invite → notification →
    /// join loop can be exercised on one Mac. Ids are prefixed "sim-".
    @Published private(set) var simulatedFriends: [SavedSofaFriend] = []
    /// Invitation id → the simulated friend it stands in for.
    private var simulatedInviteFriends: [String: SavedSofaFriend] = [:]

    /// Real saved friends plus any simulated ones, for every invite surface.
    var invitableFriends: [SavedSofaFriend] { friends + simulatedFriends }

    func clearInvitedMarks() {
        invitedFriendIDs = []
    }

    private static let simulatedNamePool =
        ["Ana", "Luis", "Sofía", "Marco", "Elena", "Diego", "Carmen", "Pau"]

    func addSimulatedFriend() {
        let used = Set(invitableFriends.map(\.name))
        let name = Self.simulatedNamePool.first { !used.contains($0) }
            ?? "Friend \(simulatedFriends.count + 1)"
        simulatedFriends.append(
            SavedSofaFriend(id: "sim-\(UUID().uuidString.prefix(8))", name: name, online: true)
        )
        AppState.shared.showToast("Added simulated friend \(name)")
    }

    func removeSimulatedFriends() {
        guard !simulatedFriends.isEmpty else { return }
        simulatedFriends = []
        clearSimulatedInvites()
        AppState.shared.showToast("Removed simulated friends")
    }

    /// Drops any pending/shown simulated invitations and their marks, so a
    /// stale sim card can never outlive its party or a removed friend.
    func clearSimulatedInvites() {
        guard !simulatedInviteFriends.isEmpty else { return }
        let simIDs = Set(simulatedInviteFriends.keys)
        simulatedInviteFriends = [:]
        invitations.removeAll { simIDs.contains($0.id) }
        invitedFriendIDs.subtract(
            Set(simulatedFriends.map(\.id))
        )
    }

    fileprivate struct Credential: Codable { let id: String; let token: String }
    private struct Profile: Decodable {
        let id: String
        let name: String
        let friendLink: String
        let authToken: String?
    }
    private struct FriendList: Decodable { let friends: [SavedSofaFriend] }
    private struct Event: Decodable {
        let type: String
        let invite: SofaPartyInvitation?
        let friend: SavedSofaFriend?
    }

    private let session = URLSession(configuration: .ephemeral)
    private var credential: Credential?
    private var socket: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var bootstrapRetryTask: Task<Void, Never>?
    private var nameUpdateTask: Task<Void, Never>?
    private var started = false
    private var pendingFriendLink: String?
    private var bootstrapRetryAttempt = 0
    private var reconnectAttempt = 0
    private var modernNotificationsAllowed = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        configureNotifications()
        Task { await bootstrap() }
    }

    func stop() {
        reconnectTask?.cancel()
        bootstrapRetryTask?.cancel()
        nameUpdateTask?.cancel()
        reconnectTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func displayNameChanged(_ name: String) {
        guard ready else { return }
        nameUpdateTask?.cancel()
        nameUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                _ = try await request(path: "/me", method: "PATCH", body: ["name": name]) as Profile
            } catch { /* the next launch refreshes it */ }
        }
    }

    func acceptFriendLink(_ link: String) {
        guard let parts = Self.friendLinkParts(link) else {
            AppState.shared.showToast("That Sofa friend link is not valid.")
            return
        }
        guard ready else {
            pendingFriendLink = link
            AppState.shared.showToast("Setting up your Sofa friends…")
            return
        }
        Task {
            do {
                let _: [String: FriendEnvelope] = try await request(
                    path: "/friends/accept", method: "POST",
                    body: ["friendID": parts.id, "code": parts.code]
                )
                await refreshFriends()
                AppState.shared.showToast("Friend saved — future invitations arrive inside Sofa.")
            } catch {
                AppState.shared.showToast("Couldn’t add this friend. Ask for a new friend link.")
            }
        }
    }

    func sendInvitation(to friend: SavedSofaFriend) {
        let state = AppState.shared
        guard state.isHosting, state.roomIsOnline,
              !state.inviteCode.isEmpty, let secret = state.sync.roomToken else {
            state.showToast("Start an online party before inviting a friend.")
            return
        }
        // A simulated friend has no real device — play out the round trip
        // locally so the notification and join can be experienced on one Mac.
        if friend.id.hasPrefix("sim-") {
            simulateInvitation(to: friend)
            return
        }
        Task {
            do {
                var body = ["friendID": friend.id, "roomID": state.inviteCode, "secret": secret]
                if let title = state.nowPlaying, !title.isEmpty { body["title"] = title }
                let response: InviteResponse = try await request(
                    path: "/invites", method: "POST",
                    body: body
                )
                if response.delivered {
                    invitedFriendIDs.insert(friend.id)
                    state.showToast("Invitation sent to \(friend.name).")
                } else {
                    // The relay already knows the friend is offline — be
                    // honest instead of letting the host wait forever, and
                    // put the link in hand for the messaging fallback.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.inviteLink, forType: .string)
                    state.showToast("\(friend.name) seems offline — link copied, send it to them.")
                }
                await refreshFriends()
            } catch {
                state.showToast("Couldn’t send the invitation to \(friend.name).")
            }
        }
    }

    /// Fakes the friend's side of an invitation: after a short beat their Sofa
    /// "receives" it (banner + in-app card). Accepting it drops them into the
    /// party, so the sender sees the avatar arrive — all on one Mac.
    private func simulateInvitation(to friend: SavedSofaFriend) {
        let state = AppState.shared
        invitedFriendIDs.insert(friend.id)
        state.showToast("Invitation sent to \(friend.name)")
        let invite = SofaPartyInvitation(
            id: "sim-invite-\(UUID().uuidString.prefix(8))",
            fromID: "sim-self",
            fromName: state.displayName,
            roomID: state.inviteCode,
            secret: state.sync.roomToken ?? "",
            title: state.nowPlaying,
            createdAt: Date().timeIntervalSince1970 * 1000,
            expiresAt: (Date().timeIntervalSince1970 + 3600) * 1000
        )
        simulatedInviteFriends[invite.id] = friend
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            // The party may have ended (or the friend been removed) mid-beat.
            guard state.isHosting, simulatedInviteFriends[invite.id] != nil else { return }
            if !invitations.contains(where: { $0.id == invite.id }) {
                invitations.append(invite)
            }
            if !modernNotificationsAllowed { requestBannerAuthorization() }
            postNotification(for: invite)
            NotificationCenter.default.post(name: .sofaShowPanel, object: nil)
            NSSound(named: "Ping")?.play()
        }
    }

    func acceptInvitation(id: String) {
        // A simulated invite: accepting it makes the fake friend join the room.
        if let friend = simulatedInviteFriends[id] {
            simulatedInviteFriends[id] = nil
            dismissInvitation(id: id)
            AppState.shared.simulateFriendJoined(friend)
            return
        }
        guard let invite = invitations.first(where: { $0.id == id }) else { return }
        let state = AppState.shared
        guard !state.inRoom, !state.hosting, !state.joining else {
            state.showToast("Leave the current party before joining \(invite.fromName).")
            return
        }
        dismissInvitation(id: id)
        state.joinAddress = invite.joinURL
        state.join(target: invite.joinURL)
    }

    func dismissInvitation(id: String) {
        invitations.removeAll { $0.id == id }
        Task {
            let _: EmptyResponse? = try? await request(path: "/invites/\(id)", method: "DELETE")
        }
    }

    private func bootstrap() async {
        do {
            switch KeychainCredential.loadOrMigrate() {
            case .found(let saved):
                credential = saved
                do {
                    let profile: Profile = try await request(path: "/me")
                    friendLink = profile.friendLink
                } catch SocialError.unauthorized {
                    // The server *definitively* rejected the token — only now is
                    // it safe to discard it and start over. Transient failures
                    // (offline, 5xx, timeout) fall through to the outer catch,
                    // which retries with backoff and keeps the credential intact,
                    // so a passing network blip never re-identifies the user.
                    credential = nil
                    KeychainCredential.delete()
                    try await register()
                }
            case .empty:
                try await register()
            case .declined:
                // The user dismissed the one-time keychain-migration prompt. Do
                // not mint a fresh identity (that would orphan their friends);
                // leave Friends idle and let a future launch re-offer it.
                throw SocialError.migrationDeclined
            }
            ready = true
            errorMessage = nil
            bootstrapRetryAttempt = 0
            await refreshFriends()
            connectEvents()
            if let pendingFriendLink {
                self.pendingFriendLink = nil
                acceptFriendLink(pendingFriendLink)
            }
        } catch SocialError.migrationDeclined {
            // Stay quietly un-ready without hammering the retry loop; the next
            // app launch re-attempts the migration.
            ready = false
            errorMessage = nil
            bootstrapRetryAttempt = 0
        } catch {
            if errorMessage != "Friends are temporarily unavailable." {
                errorMessage = "Friends are temporarily unavailable."
            }
            if ready { ready = false }
            bootstrapRetryTask?.cancel()
            let delay = retryDelay(attempt: bootstrapRetryAttempt)
            bootstrapRetryAttempt += 1
            bootstrapRetryTask = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await bootstrap()
            }
        }
    }

    private func register() async throws {
        let profile: Profile = try await request(
            path: "/register", method: "POST",
            body: ["name": AppState.shared.displayName], authenticated: false
        )
        guard let token = profile.authToken else { throw SocialError.invalidResponse }
        let value = Credential(id: profile.id, token: token)
        credential = value
        // Persist best-effort: a keychain write failure must not throw here, or
        // the outer bootstrap catch would retry and mint yet another identity on
        // every launch. The in-memory credential keeps this session working.
        try? KeychainCredential.save(value)
        friendLink = profile.friendLink
    }

    private func refreshFriends() async {
        do {
            let list: FriendList = try await request(path: "/friends")
            if friends != list.friends { friends = list.friends }
            reconnectAttempt = 0
            if errorMessage != nil { errorMessage = nil }
        } catch {
            if errorMessage != "Couldn’t refresh friends." {
                errorMessage = "Couldn’t refresh friends."
            }
        }
    }

    private func connectEvents() {
        guard let credential else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        var request = URLRequest(url: endpoint("/events", websocket: true))
        request.setValue("Bearer \(credential.id).\(credential.token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveEvents(from: task)
    }

    private func receiveEvents(from task: URLSessionWebSocketTask) {
        Task {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: throw SocialError.invalidResponse
                }
                if let event = try? JSONDecoder().decode(Event.self, from: data) {
                    reconnectAttempt = 0
                    handle(event)
                }
                if socket === task { receiveEvents(from: task) }
            } catch {
                guard socket === task else { return }
                socket = nil
                scheduleReconnect()
            }
        }
    }

    private func handle(_ event: Event) {
        switch event.type {
        case "party_invite":
            guard let invite = event.invite, invite.expiresAt / 1000 > Date().timeIntervalSince1970 else { return }
            let isNew = !invitations.contains { $0.id == invite.id }
            invitations.removeAll { $0.id == invite.id }
            invitations.append(invite)
            if !modernNotificationsAllowed { requestBannerAuthorization() }
            postNotification(for: invite)
            NotificationCenter.default.post(name: .sofaShowPanel, object: nil)
            AppState.shared.showToast("\(invite.fromName) wants to watch with you")
            // A banner needs a notarized app; until then, a sound makes the
            // panel-opening invitation impossible to miss.
            if isNew { NSSound(named: "Ping")?.play() }
        case "friend_added", "friends_changed":
            Task { await refreshFriends() }
            if let friend = event.friend {
                AppState.shared.showToast("\(friend.name) added you as a friend.")
            }
        default: break
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = retryDelay(attempt: reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            reconnectTask = nil
            connectEvents()
            await refreshFriends()
        }
    }

    /// Back off aggressively while offline or while the relay is unavailable.
    /// Jitter prevents every sleeping Mac from reconnecting on the same second.
    private func retryDelay(attempt: Int) -> Duration {
        let seconds = [5.0, 15.0, 30.0, 60.0, 300.0][min(attempt, 4)]
        let jittered = seconds * Double.random(in: 0.85...1.15)
        return .milliseconds(Int64(jittered * 1_000))
    }

    private func configureNotifications() {
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [.foreground])
        let decline = UNNotificationAction(identifier: Self.declineAction, title: "Not now")
        let category = UNNotificationCategory(
            identifier: Self.notificationCategory, actions: [join, decline],
            intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        // macOS only lets notarized apps (an Apple Developer identity) post
        // Notification Center banners. Sofa is self-signed, so this is denied —
        // we fall back to opening the panel with the invitation, plus a sound.
        // If the app is ever notarized, banners light up with no code change.
        requestBannerAuthorization()
    }

    /// Safe to call repeatedly. On this Mac (macOS 27 beta) banners are still
    /// refused even for the notarized build; if Apple's side ever starts
    /// allowing them (account propagation, OS update), this picks it up.
    private func requestBannerAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.modernNotificationsAllowed = granted }
        }
    }

    private func postNotification(for invite: SofaPartyInvitation) {
        let content = UNMutableNotificationContent()
        // "Watch “Interstellar” with Pablo?" — name the thing and the person.
        if let title = invite.title, !title.isEmpty {
            content.title = "Watch “\(title)” with \(invite.fromName)?"
        } else {
            content.title = "Watch with \(invite.fromName)?"
        }
        content.body = "Tap Join and Sofa drops you into the party, in sync."
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["inviteID": invite.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "sofa-party-\(invite.id)", content: content, trigger: nil)
        )
    }

    private func endpoint(_ path: String, websocket: Bool = false) -> URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SofaRelayURL") as? String
            ?? "https://sofa-sync-relay.pablopjc.workers.dev"
        var components = URLComponents(string: configured)!
        components.scheme = websocket ? (components.scheme == "https" ? "wss" : "ws") : components.scheme
        components.path = "/v1/social\(path)"
        return components.url!
    }

    private func request<T: Decodable>(
        path: String,
        method: String = "GET",
        body: [String: String]? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let credential else { throw SocialError.notRegistered }
            request.setValue("Bearer \(credential.id).\(credential.token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SocialError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Only 401/403 mean the credential itself is rejected. Everything
            // else (5xx, gateway errors, rate limits) is transient and must not
            // cause a caller to discard a still-valid credential. Offline /
            // timeout never reach here — session.data(for:) throws URLError.
            if http.statusCode == 401 || http.statusCode == 403 { throw SocialError.unauthorized }
            throw SocialError.server
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func friendLinkParts(_ raw: String) -> (id: String, code: String)? {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "sofa",
              url.host?.lowercased() == "friend" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "v1",
              parts[1].range(of: #"^[A-Za-z0-9_-]{22}$"#, options: .regularExpression) != nil,
              parts[2].range(of: #"^[A-Za-z0-9_-]{24}$"#, options: .regularExpression) != nil
        else { return nil }
        return (parts[1], parts[2])
    }
}

private struct FriendEnvelope: Decodable { let id: String; let name: String }
private struct InviteResponse: Decodable { let ok: Bool; let delivered: Bool }
private struct EmptyResponse: Decodable { let ok: Bool }

private enum SocialError: Error { case invalidResponse, notRegistered, server, unauthorized, migrationDeclined }

private enum KeychainCredential {
    private static let service = "com.pablo.sofa.native.social"
    private static let account = "device-credential"

    // Sofa keeps its device credential in the modern *data protection* keychain
    // (kSecUseDataProtectionKeychain), whose access is granted by the app's
    // Team-ID entitlement rather than by an interactive per-item ACL. That is
    // what stops macOS from ever asking a fresh user to "enter the login
    // keychain password". Builds signed without that entitlement (local
    // self-signed / ad-hoc dev builds) transparently fall back to the legacy
    // login keychain so Friends still works while developing.

    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    enum LoadResult {
        case found(SocialService.Credential)
        case empty                       // nothing stored anywhere → register fresh
        case declined                    // user dismissed the migration prompt → retry next launch
    }

    static func loadOrMigrate() -> LoadResult {
        // 1. Modern keychain — always silent, no prompt is ever possible here.
        var modernResult: CFTypeRef?
        var modernQuery = baseQuery(dataProtection: true)
        modernQuery[kSecReturnData as String] = true
        modernQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let modernStatus = SecItemCopyMatching(modernQuery as CFDictionary, &modernResult)
        if modernStatus == errSecSuccess,
           let data = modernResult as? Data,
           let credential = try? JSONDecoder().decode(SocialService.Credential.self, from: data) {
            return .found(credential)
        }

        // 2. Legacy login keychain. A brand-new user has nothing here, so this
        //    stays silent (errSecItemNotFound). A user upgrading from a
        //    pre-migration build has an item bound to the old signing identity —
        //    reading it shows the password prompt exactly once.
        var legacyResult: CFTypeRef?
        var legacyQuery = baseQuery(dataProtection: false)
        legacyQuery[kSecReturnData as String] = true
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyResult)

        if legacyStatus == errSecSuccess,
           let data = legacyResult as? Data,
           let credential = try? JSONDecoder().decode(SocialService.Credential.self, from: data) {
            // Copy it into the modern keychain so every future launch is silent.
            // We intentionally do NOT delete the legacy item: it's never read
            // again (the modern copy wins next launch), and deleting it could
            // itself raise a second prompt. It also stays as a safety net for a
            // dev build that lacks the entitlement. Migrate only when the modern
            // keychain is genuinely usable (errSecItemNotFound, not a missing
            // entitlement on a self-signed dev build).
            if modernStatus == errSecItemNotFound { _ = saveModern(data) }
            return .found(credential)
        }

        // The legacy item exists but we couldn't read it — the user dismissed
        // the password prompt (errSecUserCanceled / errSecAuthFailed / …).
        // Report .declined so bootstrap does NOT register a new identity over
        // the top of it; a later launch offers the migration again.
        if legacyStatus != errSecItemNotFound { return .declined }
        return .empty
    }

    static func save(_ credential: SocialService.Credential) throws {
        let data = try JSONEncoder().encode(credential)
        switch saveModern(data) {
        case errSecSuccess:
            return
        case errSecMissingEntitlement:
            try saveLegacy(data) // dev builds without the app-identifier entitlement
        default:
            throw SocialError.server
        }
    }

    static func delete() {
        SecItemDelete(baseQuery(dataProtection: true) as CFDictionary)
        deleteLegacy()
    }

    // MARK: - Modern (data protection) keychain

    private static func saveModern(_ data: Data) -> OSStatus {
        let key = baseQuery(dataProtection: true)
        let status = SecItemUpdate(key as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = key
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: - Legacy login keychain (dev-build fallback; migration source read inline above)

    private static func saveLegacy(_ data: Data) throws {
        let key = baseQuery(dataProtection: false)
        let status = SecItemUpdate(key as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SocialError.server }
        } else if status != errSecSuccess {
            throw SocialError.server
        }
    }

    private static func deleteLegacy() {
        SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
    }
}
