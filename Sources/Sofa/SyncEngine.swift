import Foundation
import Network

/// A sync message. Mirrors the Electron (legacy) JSON protocol exactly, so a
/// Swift Sofa and a legacy Sofa can share a room.
struct SyncMessage {
    var type: String
    var time: Double?
    var playing: Bool?
    var name: String?
    var art: String?      // poster / artwork URL
    var token: String?    // room secret, presented in "hello"
    var count: Int?
    var from: String?
    var sentAt: Double?   // ms since epoch

    var latencySeconds: Double {
        guard let sentAt else { return 0 }
        return min(2, max(0, (Date().timeIntervalSince1970 * 1000 - sentAt) / 1000))
    }

    /// Keep every client frame inside the public relay's protocol limits. This
    /// also protects the LAN path from non-finite player times and oversized
    /// metadata produced by a browser tab.
    func normalized() -> SyncMessage {
        var message = self
        message.name = Self.limitedUTF16(name, to: 256)
        if let art, art.utf16.count <= 4_096,
           let scheme = URL(string: art)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            message.art = art
        } else {
            message.art = nil
        }
        if let time {
            message.time = time.isFinite ? min(1_000_000_000, max(0, time)) : nil
        }
        if let sentAt, !sentAt.isFinite || sentAt < 0 {
            message.sentAt = nil
        }
        return message
    }

    private static func limitedUTF16(_ value: String?, to limit: Int) -> String? {
        guard let value else { return nil }
        guard value.utf16.count > limit else { return value }
        return String(decoding: value.utf16.prefix(limit), as: UTF16.self)
    }

    func encoded() -> Data? {
        let message = normalized()
        // Never put an incomplete control frame on the wire. In particular,
        // AVPlayer can briefly report an indefinite/NaN time while changing
        // items; normalized() drops it, and the whole event must then be
        // dropped instead of letting the public relay close the socket.
        switch message.type {
        case "loaded":
            guard message.name != nil else { return nil }
        case "play", "pause", "tick":
            guard message.time != nil else { return nil }
        case "seek":
            guard message.time != nil, message.playing != nil else { return nil }
        default:
            break
        }
        var dict: [String: Any] = ["type": message.type]
        if let time = message.time { dict["time"] = time }
        if let playing = message.playing { dict["playing"] = playing }
        if let name = message.name { dict["name"] = name }
        if let art = message.art { dict["art"] = art }
        if let token = message.token { dict["token"] = token }
        if let count = message.count { dict["count"] = count }
        if let from = message.from { dict["from"] = from }
        if let sentAt = message.sentAt { dict["sentAt"] = sentAt }
        return try? JSONSerialization.data(withJSONObject: dict)
    }

    static func decode(_ data: Data) -> SyncMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        return SyncMessage(
            type: type,
            time: (obj["time"] as? NSNumber)?.doubleValue,
            playing: obj["playing"] as? Bool,
            name: obj["name"] as? String,
            art: obj["art"] as? String,
            token: obj["token"] as? String,
            count: (obj["count"] as? NSNumber)?.intValue,
            from: obj["from"] as? String,
            sentAt: (obj["sentAt"] as? NSNumber)?.doubleValue
        ).normalized()
    }
}

/// The one-time response from the public relay when a host creates a room.
struct OnlineRoom: Decodable, Equatable {
    let roomID: String
    let secret: String
    let webSocketURL: String?
    let inviteURL: String?
    let expiresAt: Double?
}

enum OnlineRoomError: LocalizedError {
    case relayNotConfigured
    case invalidRelayURL
    case createFailed
    case invalidResponse
    case connectionFailed
    case network(String)

    var errorDescription: String? {
        switch self {
        case .relayNotConfigured:
            return "The online service is not configured in this build."
        case .invalidRelayURL:
            return "The online service address is invalid."
        case .createFailed:
            return "The online service could not create a room."
        case .invalidResponse:
            return "The online service returned an invalid room."
        case .connectionFailed:
            return "Sofa could not connect to the new online room."
        case .network(let message):
            return "Check your internet connection (\(message))."
        }
    }
}

enum LocalHostingError: LocalizedError {
    case listenerCancelled
    case selfConnectionFailed

    var errorDescription: String? {
        switch self {
        case .listenerCancelled:
            return "The local network listener stopped before it was ready."
        case .selfConnectionFailed:
            return "Sofa could not connect to its local party listener."
        }
    }
}

/// Hosts the relay (when hosting) and holds the client connection to the room.
/// The host also connects to its own relay, exactly like the legacy app.
///
/// Security: joining requires the room's secret. The invite link carries it
/// (sofa://join/host:port/SECRET); a peer's first message must be a "hello"
/// with the right token or the relay drops the connection — so knowing the IP
/// and port (eg. a port scan of the Wi-Fi) is no longer enough to get in.
@MainActor
final class SyncEngine {
    static let port: UInt16 = 7420

    weak var state: AppState?
    let myId = UUID().uuidString.prefix(8).lowercased()

    private var listener: NWListener?
    private var listenerReady = false
    private var localHostingID: UUID?
    private var localHostingCompletion: ((Result<Void, Error>) -> Void)?
    private var serverPeers: [NWConnection] = []
    private var authedPeers = Set<ObjectIdentifier>()
    private var client: NWConnection?
    private enum ConnectionPurpose {
        case initial(generation: UInt64)
        case reconnect(generation: UInt64)

        var generation: UInt64 {
            switch self {
            case .initial(let generation), .reconnect(let generation): return generation
            }
        }

        var isReconnect: Bool {
            if case .reconnect = self { return true }
            return false
        }
    }

    private struct PendingWelcome {
        let connection: NWConnection
        let tracker: ConnectTracker
        let purpose: ConnectionPurpose
    }

    private struct OnlineReconnectTarget {
        let roomID: String
        let secret: String
    }

    private enum ReceiveEvent: Sendable {
        case message(Data)
        case closed
    }

    private var awaitingWelcome: PendingWelcome?
    private var presenceTimer: Timer?
    private var connectionGeneration: UInt64 = 0
    private var onlineReconnectTarget: OnlineReconnectTarget?
    private var reconnectAllowed = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?

    /// The room secret: generated when hosting, taken from the link when joining.
    private(set) var roomToken: String?

    /// Unambiguous alphabet (no 0/O or 1/I) — the code may be read out loud.
    static func generateToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// The relay origin is kept in Info.plist so a future infrastructure move
    /// does not scatter hostnames through the code. The environment override is
    /// useful for local integration tests (`http://127.0.0.1:8787`).
    static var relayBaseURL: URL? {
        let raw = ProcessInfo.processInfo.environment["SOFA_RELAY_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "SofaRelayURL") as? String
        guard let raw, let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        return url
    }

    static func onlineRoomURL(baseURL: URL, roomID: String) -> URL? {
        let httpURL = baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rooms", isDirectory: true)
            .appendingPathComponent(roomID, isDirectory: false)
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        return components.url
    }

    private static func roomCollectionURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rooms", isDirectory: false)
    }

    private static var relayClientID: String {
        let defaults = UserDefaults.standard
        let key = "SofaRelayClientID"
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil {
            return existing.lowercased()
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    // MARK: - Hosting (relay)

    /// Starts the embedded LAN relay. Success is reported only after the fixed
    /// port is listening and Sofa's own WebSocket has authenticated against it.
    func startHosting(completion: @escaping (Result<Void, Error>) -> Void) {
        guard listener == nil, localHostingID == nil else {
            if listenerReady {
                completion(.success(()))
            } else {
                completion(.failure(LocalHostingError.listenerCancelled))
            }
            return
        }
        roomToken = Self.generateToken()
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        } catch {
            roomToken = nil
            completion(.failure(error))
            return
        }
        let hostingID = UUID()
        localHostingID = hostingID
        localHostingCompletion = completion
        listenerReady = false
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.acceptPeer(conn) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    guard self.localHostingID == hostingID else { return }
                    self.listenerReady = true
                    self.connectToSelf { [weak self, weak listener] ok in
                        guard let self, let listener, listener === self.listener,
                              self.localHostingID == hostingID else { return }
                        if ok {
                            self.finishLocalHosting(hostingID, result: .success(()))
                        } else {
                            self.failLocalHosting(
                                listener,
                                hostingID: hostingID,
                                error: LocalHostingError.selfConnectionFailed
                            )
                        }
                    }
                case .waiting(let error), .failed(let error):
                    if self.localHostingID == hostingID {
                        self.failLocalHosting(listener, hostingID: hostingID, error: error)
                    } else if self.listenerReady {
                        self.listener = nil
                        self.listenerReady = false
                        self.stop()
                        self.state?.localPartyStoppedUnexpectedly()
                    }
                case .cancelled:
                    if self.localHostingID == hostingID {
                        self.failLocalHosting(
                            listener,
                            hostingID: hostingID,
                            error: LocalHostingError.listenerCancelled
                        )
                    } else if self.listenerReady {
                        self.listener = nil
                        self.listenerReady = false
                        self.stop()
                        self.handleDisconnect()
                    }
                default:
                    break
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    /// Creates an ephemeral room on the public relay, then authenticates the
    /// host's own WSS connection. Success is reported only after `welcome`, so
    /// the UI can never hand out a link for a room it did not actually enter.
    func startOnlineHosting(completion: @escaping (Result<OnlineRoom, Error>) -> Void) {
        guard let baseURL = Self.relayBaseURL else {
            completion(.failure(OnlineRoomError.relayNotConfigured))
            return
        }
        let generation = beginConnectionGeneration()
        let collectionURL = Self.roomCollectionURL(baseURL: baseURL)
        var request = URLRequest(url: collectionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.relayClientID, forHTTPHeaderField: "X-Sofa-Client-ID")
        request.setValue("1", forHTTPHeaderField: "X-Sofa-Protocol")
        request.httpBody = Data("{}".utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                if let error {
                    completion(.failure(OnlineRoomError.network(error.localizedDescription)))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 201,
                      let data,
                      let room = try? JSONDecoder().decode(OnlineRoom.self, from: data),
                      case .online(let parsedID, let parsedSecret) = RoomTarget.parse(
                        "sofa://join/v1/\(room.roomID)/\(room.secret)"
                      ),
                      parsedID == room.roomID.uppercased(),
                      parsedSecret == room.secret,
                      let socketURL = Self.onlineRoomURL(baseURL: baseURL, roomID: room.roomID)
                else {
                    if let http = response as? HTTPURLResponse, http.statusCode != 201 {
                        completion(.failure(OnlineRoomError.createFailed))
                    } else {
                        completion(.failure(OnlineRoomError.invalidResponse))
                    }
                    return
                }

                self.onlineReconnectTarget = OnlineReconnectTarget(
                    roomID: room.roomID.uppercased(),
                    secret: room.secret
                )
                self.connect(
                    toWebSocketURL: socketURL,
                    token: room.secret,
                    timeout: 12,
                    purpose: .initial(generation: generation)
                ) { ok in
                    completion(ok ? .success(room) : .failure(OnlineRoomError.connectionFailed))
                }
            }
        }.resume()
    }

    private func connectToSelf(completion: @escaping (Bool) -> Void) {
        connect(to: "127.0.0.1:\(Self.port)", token: roomToken, completion: completion)
    }

    private func finishLocalHosting(_ hostingID: UUID, result: Result<Void, Error>) {
        guard localHostingID == hostingID, let completion = localHostingCompletion else { return }
        localHostingID = nil
        localHostingCompletion = nil
        completion(result)
    }

    private func failLocalHosting(
        _ failedListener: NWListener,
        hostingID: UUID,
        error: Error
    ) {
        guard failedListener === listener, localHostingID == hostingID,
              let completion = localHostingCompletion else { return }
        localHostingID = nil
        localHostingCompletion = nil
        listener = nil
        listenerReady = false
        failedListener.cancel()
        stop()
        completion(.failure(error))
    }

    private func acceptPeer(_ conn: NWConnection) {
        serverPeers.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            Task { @MainActor in
                guard let self, let conn else { return }
                switch st {
                case .failed, .cancelled:
                    self.serverPeers.removeAll { $0 === conn }
                    self.authedPeers.remove(ObjectIdentifier(conn))
                    self.broadcastPeerCount()
                default: break
                }
            }
        }
        receiveLoop(on: conn) { [weak self, weak conn] event in
            Task { @MainActor in
                guard let self, let conn else { return }
                if case .message(let data) = event {
                    self.relayIncoming(data, from: conn)
                }
            }
        }
        conn.start(queue: .main)
        // A peer that hasn't authenticated within 5s is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak conn] in
            guard let self, let conn else { return }
            if !self.authedPeers.contains(ObjectIdentifier(conn)) {
                conn.cancel()
            }
        }
    }

    /// Relay-side routing: gate on the room token, then forward to the others.
    private func relayIncoming(_ data: Data, from conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        var outgoing = data

        if !authedPeers.contains(id) {
            // First message must be a hello with the right secret.
            guard let msg = SyncMessage.decode(data), msg.type == "hello",
                  let token = msg.token, token == roomToken else {
                conn.cancel()
                return
            }
            authedPeers.insert(id)
            var sanitizedHello = msg
            sanitizedHello.token = nil
            outgoing = sanitizedHello.encoded() ?? data
            if let welcome = SyncMessage(type: "welcome").encoded() {
                send(data: welcome, over: conn)
            }
            broadcastPeerCount()
            // Fall through: relay the hello so existing peers learn the name.
        } else if var hello = SyncMessage.decode(data), hello.type == "hello" {
            // Presence hellos do not need to disclose the room credential to
            // already-connected peers, even on a trusted LAN.
            hello.token = nil
            outgoing = hello.encoded() ?? data
        }

        for peer in serverPeers where peer !== conn && authedPeers.contains(ObjectIdentifier(peer)) {
            send(data: outgoing, over: peer)
        }
    }

    private func broadcastPeerCount() {
        let msg = SyncMessage(type: "peers", count: authedPeers.count)
        guard let data = msg.encoded() else { return }
        for peer in serverPeers where authedPeers.contains(ObjectIdentifier(peer)) {
            send(data: data, over: peer)
        }
    }

    // MARK: - Client

    /// Connects and authenticates. `completion(true)` only fires once the host
    /// has accepted our room secret (the "welcome") — a wrong or missing code
    /// looks like a failed join, not a half-open room.
    func connect(to address: String, token: String?, completion: @escaping (Bool) -> Void) {
        guard var components = URLComponents(string: "ws://\(address)"),
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            completion(false)
            return
        }
        if components.port == nil { components.port = Int(Self.port) }
        guard let wsURL = components.url else {
            completion(false)
            return
        }
        let generation = beginConnectionGeneration()
        connect(
            toWebSocketURL: wsURL,
            token: token,
            timeout: 6,
            purpose: .initial(generation: generation),
            completion: completion
        )
    }

    func connectOnline(roomID: String, secret: String, completion: @escaping (Bool) -> Void) {
        guard let baseURL = Self.relayBaseURL,
              let wsURL = Self.onlineRoomURL(baseURL: baseURL, roomID: roomID) else {
            completion(false)
            return
        }
        let generation = beginConnectionGeneration()
        onlineReconnectTarget = OnlineReconnectTarget(roomID: roomID.uppercased(), secret: secret)
        connect(
            toWebSocketURL: wsURL,
            token: secret,
            timeout: 12,
            purpose: .initial(generation: generation),
            completion: completion
        )
    }

    private func connect(
        toWebSocketURL wsURL: URL,
        token: String?,
        timeout: TimeInterval,
        purpose: ConnectionPurpose,
        completion: @escaping (Bool) -> Void
    ) {
        guard purpose.generation == connectionGeneration else { return }
        guard let scheme = wsURL.scheme?.lowercased(),
              (scheme == "ws" || scheme == "wss"),
              wsURL.host != nil else {
            completion(false)
            return
        }
        // A failed attempt must never leave its credential behind for the next
        // link. This also fixes switching from a bad invite into Test Zone.
        roomToken = token

        let params: NWParameters = scheme == "wss" ? .tls : .tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // WebSocket over NWConnection needs a URL endpoint — with a plain
        // host:port endpoint the HTTP upgrade handshake is malformed and the
        // connection aborts (POSIX 53).
        let conn = NWConnection(to: .url(wsURL), using: params)

        let tracker = ConnectTracker(completion: completion)
        if let pending = awaitingWelcome { _ = pending.tracker.finish(false) }
        awaitingWelcome = PendingWelcome(
            connection: conn,
            tracker: tracker,
            purpose: purpose
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak conn] in
            guard let self, let conn, conn === self.client,
                  let pending = self.awaitingWelcome,
                  pending.connection === conn else { return }
            self.endClientConnection(conn)
        }

        conn.stateUpdateHandler = { [weak self, weak conn] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready:
                    guard let conn, conn === self.client else { return }
                    // Introduce ourselves; welcome (or timeout/close) decides.
                    self.sendRaw(SyncMessage(type: "hello",
                                             name: self.state?.displayName,
                                             token: token))
                case .failed, .cancelled:
                    // Only a *current* connection dying is a disconnect. When a
                    // new room replaces an old one, cancelling the old client
                    // fires this too — that must not flip the fresh room to
                    // "Disconnected" (the ghost state you could see after
                    // hopping from a dead room into Test Zone).
                    guard let conn else { return }
                    self.endClientConnection(conn)
                default: break
                }
            }
        }
        receiveLoop(on: conn) { [weak self, weak conn] event in
            Task { @MainActor in
                guard let conn else { return }
                switch event {
                case .message(let data): self?.handleIncoming(data, from: conn)
                case .closed: self?.endClientConnection(conn)
                }
            }
        }
        let oldClient = client
        client = conn
        oldClient?.cancel()
        conn.start(queue: .main)
    }

    /// Starts a new user-requested connection and invalidates every retry and
    /// callback belonging to the previous one.
    @discardableResult
    private func beginConnectionGeneration() -> UInt64 {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAllowed = false
        reconnectAttempt = 0
        onlineReconnectTarget = nil
        presenceTimer?.invalidate()
        presenceTimer = nil

        let pending = awaitingWelcome
        awaitingWelcome = nil
        let oldClient = client
        client = nil
        oldClient?.cancel()
        if let pending { _ = pending.tracker.finish(false) }

        connectionGeneration &+= 1
        return connectionGeneration
    }

    /// One terminal path for transport errors, welcome timeouts and WebSocket
    /// close frames. Only a connection that previously welcomed, or a retry of
    /// that same generation, is eligible to reconnect.
    private func endClientConnection(_ conn: NWConnection) {
        guard conn === client else { return }
        let pending = awaitingWelcome?.connection === conn ? awaitingWelcome : nil
        let generation = pending?.purpose.generation ?? connectionGeneration
        let shouldReconnect = reconnectAllowed
            && (pending == nil || pending?.purpose.isReconnect == true)

        awaitingWelcome = nil
        client = nil
        presenceTimer?.invalidate()
        presenceTimer = nil
        conn.cancel()
        if let pending { _ = pending.tracker.finish(false) }

        guard generation == connectionGeneration else { return }
        if shouldReconnect {
            scheduleOnlineReconnect(generation: generation)
        } else if pending == nil {
            handleDisconnect()
        } else if pending?.purpose.isReconnect == false {
            // A rejected/failed first join must not retain its capability
            // secret after the completion has returned to the idle screen.
            onlineReconnectTarget = nil
            roomToken = nil
        }
    }

    private func scheduleOnlineReconnect(generation: UInt64) {
        guard generation == connectionGeneration,
              reconnectAllowed,
              onlineReconnectTarget != nil,
              let state, state.inRoom, state.roomIsOnline else { return }

        state.markOnlineReconnecting()
        reconnectWorkItem?.cancel()
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      generation == self.connectionGeneration,
                      self.reconnectAllowed,
                      let target = self.onlineReconnectTarget,
                      let baseURL = Self.relayBaseURL,
                      let wsURL = Self.onlineRoomURL(baseURL: baseURL, roomID: target.roomID)
                else { return }
                self.reconnectWorkItem = nil
                self.connect(
                    toWebSocketURL: wsURL,
                    token: target.secret,
                    timeout: 12,
                    purpose: .reconnect(generation: generation)
                ) { _ in }
            }
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Periodic presence: keeps names fresh and lets stale friends expire.
    func startPresence() {
        presenceTimer?.invalidate()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let state = self.state, state.inRoom else { return }
                self.sendRaw(SyncMessage(type: "hello", name: state.displayName))
                state.pruneFriends(olderThan: 16)
            }
        }
    }

    private func handleDisconnect() {
        guard let state, state.inRoom else { return }
        state.disconnected = true
        state.statusLabel = "Disconnected"
        state.showToast("Connection lost — the party ended")
    }

    func stop() {
        sendRaw(SyncMessage(type: "bye"))
        localHostingID = nil
        localHostingCompletion = nil
        listenerReady = false
        presenceTimer?.invalidate(); presenceTimer = nil
        reconnectWorkItem?.cancel(); reconnectWorkItem = nil
        reconnectAllowed = false
        reconnectAttempt = 0
        onlineReconnectTarget = nil
        connectionGeneration &+= 1
        let pending = awaitingWelcome
        awaitingWelcome = nil
        let oldClient = client
        client = nil
        oldClient?.cancel()
        if let pending { _ = pending.tracker.finish(false) }
        for p in serverPeers { p.cancel() }
        serverPeers = []
        authedPeers = []
        let oldListener = listener
        listener = nil
        oldListener?.cancel()
        roomToken = nil
    }

    // MARK: - Message plumbing

    nonisolated private func receiveLoop(
        on conn: NWConnection,
        handler: @escaping @Sendable (ReceiveEvent) -> Void
    ) {
        conn.receiveMessage { [weak self, weak conn] data, context, _, error in
            if let data, !data.isEmpty { handler(.message(data)) }
            let webSocket = context?.protocolMetadata(
                definition: NWProtocolWebSocket.definition
            ) as? NWProtocolWebSocket.Metadata
            if error != nil || webSocket?.opcode == .close {
                handler(.closed)
                return
            }
            if let conn, conn.state != .cancelled {
                self?.receiveLoop(on: conn, handler: handler)
            }
        }
    }

    nonisolated private func send(data: Data, over conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .contentProcessed { _ in })
    }

    /// Send a message to the room (stamped with our id and timestamp).
    func send(_ message: SyncMessage) {
        guard let state, state.inRoom else { return }
        sendRaw(message)
    }

    /// Like send(), but also usable during the handshake (before inRoom).
    private func sendRaw(_ message: SyncMessage) {
        var msg = message
        msg.from = String(myId)
        msg.sentAt = Date().timeIntervalSince1970 * 1000
        guard let data = msg.encoded(), let client else { return }
        send(data: data, over: client)
    }

    // MARK: - Incoming routing

    private func handleIncoming(_ data: Data, from conn: NWConnection) {
        guard conn === client else { return }
        guard let msg = SyncMessage.decode(data) else { return }
        if msg.from == String(myId) { return }
        guard let state = self.state else { return }
        do {
            switch msg.type {
            case "welcome":
                if let pending = awaitingWelcome, pending.connection === conn {
                    let restored = pending.purpose.isReconnect
                    reconnectAllowed = onlineReconnectTarget != nil
                    reconnectAttempt = 0
                    reconnectWorkItem?.cancel()
                    reconnectWorkItem = nil
                    awaitingWelcome = nil
                    _ = pending.tracker.finish(true)
                    guard pending.purpose.generation == connectionGeneration,
                          conn === client else { return }
                    startPresence()
                    if restored { state.markOnlineConnectionRestored() }
                }
            case "hello":
                if let id = msg.from {
                    let isNew = state.upsertFriend(id: id, name: msg.name ?? "Friend")
                    // Introduce ourselves back so latecomers learn our name too.
                    if isNew {
                        sendRaw(SyncMessage(type: "hello", name: state.displayName))
                    }
                }
            case "bye":
                if let id = msg.from { state.removeFriend(id: id) }
            case "peers":
                state.peerCount = msg.count ?? 0
            case "loaded":
                let name = msg.name ?? "media"
                state.friendNowPlayingArt = msg.art
                if state.friendNowPlaying != name {
                    state.friendNowPlaying = name
                    state.showToast("Your friend is watching “\(name)”")
                }
            case "play", "pause", "seek", "tick":
                if state.playerChoice != .builtin {
                    PlayerBridge.shared.applyRemote(msg)
                } else {
                    state.builtin.applyRemote(msg)
                }
            default:
                break
            }
        }
    }
}

/// Thread-safe one-shot connect completion guard.
final class ConnectTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    /// Returns true if this call performed the completion.
    func finish(_ ok: Bool) -> Bool {
        lock.lock()
        if completed {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        completion(ok)
        return true
    }
}
