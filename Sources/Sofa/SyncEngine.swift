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
            count: (obj["count"] as? NSNumber)?.intValue,
            from: obj["from"] as? String,
            sentAt: (obj["sentAt"] as? NSNumber)?.doubleValue
        )
    }
}

/// Hosts the relay (when hosting) and holds the client connection to the room.
/// The host also connects to its own relay, exactly like the legacy app.
@MainActor
final class SyncEngine {
    static let port: UInt16 = 7420

    weak var state: AppState?
    private let myId = UUID().uuidString.prefix(8).lowercased()

    private var listener: NWListener?
    private var serverPeers: [NWConnection] = []
    private var client: NWConnection?

    // MARK: - Hosting (relay)

    func startHosting() throws {
        guard listener == nil else {
            connectToSelf()
            return
        }
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
        connect(to: "127.0.0.1:\(Self.port)") { _ in }
    }

    private func acceptPeer(_ conn: NWConnection) {
        serverPeers.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            Task { @MainActor in
                guard let self, let conn else { return }
                switch st {
                case .failed, .cancelled:
                    self.serverPeers.removeAll { $0 === conn }
                    self.broadcastPeerCount()
                default: break
                }
            }
        }
        receiveLoop(on: conn) { [weak self] data in
            // Relay every message to all other peers
            Task { @MainActor in
                guard let self else { return }
                for peer in self.serverPeers where peer !== conn {
                    self.send(data: data, over: peer)
                }
            }
        }
        conn.start(queue: .main)
        // Give the WebSocket handshake a beat before announcing the count.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.broadcastPeerCount()
        }
    }

    private func broadcastPeerCount() {
        let msg = SyncMessage(type: "peers", count: serverPeers.count)
        guard let data = msg.encoded() else { return }
        for peer in serverPeers {
            send(data: data, over: peer)
        }
    }

    // MARK: - Client

    func connect(to address: String, completion: @escaping (Bool) -> Void) {
        let parts = address.split(separator: ":")
        let host = String(parts.first ?? "")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? Self.port : Self.port
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }

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
        _ = nwPort
        let conn = NWConnection(to: .url(wsURL), using: params)

        let tracker = ConnectTracker(completion: completion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak conn] in
            if tracker.finish(false) { conn?.cancel() }
        }

        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                switch st {
                case .ready:
                    _ = tracker.finish(true)
                case .failed, .cancelled:
                    if !tracker.finish(false) { self?.handleDisconnect() }
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

    private func handleDisconnect() {
        guard let state, state.inRoom else { return }
        state.disconnected = true
        state.statusLabel = "Disconnected"
        state.showToast("Connection lost — the party ended")
    }

    func stop() {
        client?.cancel(); client = nil
        for p in serverPeers { p.cancel() }
        serverPeers = []
        listener?.cancel(); listener = nil
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
