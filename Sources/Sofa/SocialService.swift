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
            state.showToast("Start an online party before inviting a saved friend.")
            return
        }
        Task {
            do {
                var body = ["friendID": friend.id, "roomID": state.inviteCode, "secret": secret]
                if let title = state.nowPlaying, !title.isEmpty { body["title"] = title }
                let _: InviteResponse = try await request(
                    path: "/invites", method: "POST",
                    body: body
                )
                state.showToast("Invitation sent to \(friend.name).")
                await refreshFriends()
            } catch {
                state.showToast("Couldn’t send the invitation to \(friend.name).")
            }
        }
    }

    func acceptInvitation(id: String) {
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
            if let saved = KeychainCredential.load() {
                credential = saved
                do {
                    let profile: Profile = try await request(path: "/me")
                    friendLink = profile.friendLink
                } catch {
                    credential = nil
                    KeychainCredential.delete()
                    try await register()
                }
            } else {
                try await register()
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
        try KeychainCredential.save(value)
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
            postNotification(for: invite)
            NotificationCenter.default.post(name: .sofaShowPanel, object: nil)
            AppState.shared.showToast("\(invite.fromName) invited you to watch together")
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.modernNotificationsAllowed = granted }
        }
    }

    private func postNotification(for invite: SofaPartyInvitation) {
        let content = UNMutableNotificationContent()
        content.title = "\(invite.fromName) invited you to watch together"
        content.body = invite.title.map { "Watch “\($0)” together?" }
            ?? "Open Sofa to join the party."
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
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

private enum SocialError: Error { case invalidResponse, notRegistered, server }

private enum KeychainCredential {
    private static let service = "com.pablo.sofa.native.social"
    private static let account = "device-credential"

    static func load() -> SocialService.Credential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SocialService.Credential.self, from: data)
    }

    static func save(_ credential: SocialService.Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw SocialError.server }
        } else if status != errSecSuccess {
            throw SocialError.server
        }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
