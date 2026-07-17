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

    func encoded() -> Data? {
        var dict: [String: Any] = ["type": type]
        if let time { dict["time"] = time }
        if let playing { dict["playing"] = playing }
        if let name { dict["name"] = name }
        if let art { dict["art"] = art }
        if let token { dict["token"] = token }
        if let count { dict["count"] = count }
        if let from { dict["from"] = from }
        if let sentAt { dict["sentAt"] = sentAt }
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
        )
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
    private var serverPeers: [NWConnection] = []
    private var authedPeers = Set<ObjectIdentifier>()
    private var client: NWConnection?
    private var awaitingWelcome: ConnectTracker?
    private var presenceTimer: Timer?

    /// The room secret: generated when hosting, taken from the link when joining.
    private(set) var roomToken: String?

    /// Unambiguous alphabet (no 0/O or 1/I) — the code may be read out loud.
    static func generateToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Hosting (relay)

    func startHosting() throws {
        if listener != nil {
            connectToSelf()
            return
        }
        roomToken = Self.generateToken()
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.acceptPeer(conn) }
        }
        listener.start(queue: .main)
        self.listener = listener
        connectToSelf()
    }

    private func connectToSelf() {
        connect(to: "127.0.0.1:\(Self.port)", token: roomToken) { _ in }
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
        receiveLoop(on: conn) { [weak self, weak conn] data in
            Task { @MainActor in
                guard let self, let conn else { return }
                self.relayIncoming(data, from: conn)
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

        if !authedPeers.contains(id) {
            // First message must be a hello with the right secret.
            guard let msg = SyncMessage.decode(data), msg.type == "hello",
                  let token = msg.token, token == roomToken else {
                conn.cancel()
                return
            }
            authedPeers.insert(id)
            if let welcome = SyncMessage(type: "welcome").encoded() {
                send(data: welcome, over: conn)
            }
            broadcastPeerCount()
            // Fall through: relay the hello so existing peers learn the name.
        }

        for peer in serverPeers where peer !== conn && authedPeers.contains(ObjectIdentifier(peer)) {
            send(data: data, over: peer)
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
        let parts = address.split(separator: ":")
        let host = String(parts.first ?? "")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? Self.port : Self.port
        guard !host.isEmpty else {
            completion(false)
            return
        }
        if roomToken == nil { roomToken = token }

        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // WebSocket over NWConnection needs a URL endpoint — with a plain
        // host:port endpoint the HTTP upgrade handshake is malformed and the
        // connection aborts (POSIX 53).
        guard let wsURL = URL(string: "ws://\(host):\(port)") else {
            completion(false)
            return
        }
        let conn = NWConnection(to: .url(wsURL), using: params)

        let tracker = ConnectTracker(completion: completion)
        awaitingWelcome = tracker
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak conn] in
            if tracker.finish(false) { conn?.cancel() }
        }

        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready:
                    // Introduce ourselves; the welcome (or the 6s timeout) decides.
                    self.sendRaw(SyncMessage(type: "hello",
                                             name: self.state?.displayName,
                                             token: token ?? self.roomToken))
                case .failed, .cancelled:
                    if !tracker.finish(false) { self.handleDisconnect() }
                default: break
                }
            }
        }
        receiveLoop(on: conn) { [weak self] data in
            Task { @MainActor in self?.handleIncoming(data) }
        }
        client?.cancel()
        client = conn
        conn.start(queue: .main)
    }

    /// Periodic presence: keeps names fresh and lets stale friends expire.
    func startPresence() {
        presenceTimer?.invalidate()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let state = self.state, state.inRoom else { return }
                self.sendRaw(SyncMessage(type: "hello", name: state.displayName, token: self.roomToken))
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
        presenceTimer?.invalidate(); presenceTimer = nil
        awaitingWelcome = nil
        client?.cancel(); client = nil
        for p in serverPeers { p.cancel() }
        serverPeers = []
        authedPeers = []
        listener?.cancel(); listener = nil
        roomToken = nil
    }

    // MARK: - Message plumbing

    nonisolated private func receiveLoop(on conn: NWConnection, handler: @escaping @Sendable (Data) -> Void) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            if let data, !data.isEmpty { handler(data) }
            if error == nil, let conn, conn.state != .cancelled {
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

    private func handleIncoming(_ data: Data) {
        guard let msg = SyncMessage.decode(data) else { return }
        if msg.from == String(myId) { return }
        guard let state = self.state else { return }
        do {
            switch msg.type {
            case "welcome":
                _ = awaitingWelcome?.finish(true)
                awaitingWelcome = nil
                startPresence()
            case "hello":
                if let id = msg.from {
                    let isNew = state.upsertFriend(id: id, name: msg.name ?? "Friend")
                    // Introduce ourselves back so latecomers learn our name too.
                    if isNew {
                        sendRaw(SyncMessage(type: "hello", name: state.displayName, token: roomToken))
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
        lock.lock(); defer { lock.unlock() }
        if completed { return false }
        completed = true
        completion(ok)
        return true
    }
}
