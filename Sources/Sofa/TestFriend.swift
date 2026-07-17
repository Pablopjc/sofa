import Foundation
import Network

/// A fake second person for Test Zone.
///
/// It's a real peer: it joins the real room over the real WebSocket relay, so
/// pressing its buttons exercises the whole path — network, message routing,
/// player control and the menu bar's "friends connected" sofa — exactly as a
/// friend on another Mac would. That's everything you otherwise can't test
/// without a second person.
@MainActor
final class TestFriend: ObservableObject {
    @Published var connected = false

    private var conn: NWConnection?
    private let id = "test-friend"

    /// Last playback position we heard about, so the skip buttons are relative
    /// to whatever is actually playing.
    private(set) var lastKnownTime: Double = 0
    private var lastHeardAt = Date()
    private var isPlaying = false

    /// Where playback is *right now*, extrapolating if it's rolling.
    var estimatedTime: Double {
        guard isPlaying else { return lastKnownTime }
        return lastKnownTime + Date().timeIntervalSince(lastHeardAt)
    }

    private var roomToken: String?
    private var greeted = Set<String>()
    private var presenceTimer: Timer?

    func join(token: String?) {
        let port = SyncEngine.port
        roomToken = token
        leave()
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        let conn = NWConnection(to: .url(url), using: params)

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connected = true
                    // Authenticate and introduce ourselves like a real friend,
                    // and keep saying hello so the roster entry stays fresh.
                    self.send(SyncMessage(type: "hello", name: "Test Friend", token: self.roomToken))
                    self.startPresence()
                case .failed, .cancelled: self.connected = false
                default: break
                }
            }
        }
        receiveLoop(on: conn)
        self.conn = conn
        conn.start(queue: .main)
    }

    func leave() {
        presenceTimer?.invalidate(); presenceTimer = nil
        greeted = []
        conn?.cancel()
        conn = nil
        connected = false
    }

    private func startPresence() {
        presenceTimer?.invalidate()
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.send(SyncMessage(type: "hello", name: "Test Friend", token: self.roomToken))
            }
        }
    }

    // MARK: - Things the "friend" can do

    func pressPlay() { send(SyncMessage(type: "play", time: estimatedTime)) }
    func pressPause() { send(SyncMessage(type: "pause", time: estimatedTime)) }

    func skip(by seconds: Double) {
        let target = max(0, estimatedTime + seconds)
        send(SyncMessage(type: "seek", time: target, playing: isPlaying))
    }

    func announceLoaded() {
        send(SyncMessage(type: "loaded", name: "Your friend’s copy"))
    }

    // MARK: - Plumbing

    private func send(_ message: SyncMessage) {
        guard let conn, connected else { return }
        var msg = message
        msg.from = id
        msg.sentAt = Date().timeIntervalSince1970 * 1000
        guard let data = msg.encoded() else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .contentProcessed { _ in })
    }

    nonisolated private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.track(data) }
            }
            if error == nil, let conn, conn.state != .cancelled {
                self?.receiveLoop(on: conn)
            }
        }
    }

    /// Follow along with what the real side is doing, so skips land sensibly.
    private func track(_ data: Data) {
        guard let msg = SyncMessage.decode(data), msg.from != id else { return }
        switch msg.type {
        case "hello":
            if let from = msg.from, !greeted.contains(from) {
                greeted.insert(from)
                send(SyncMessage(type: "hello", name: "Test Friend", token: roomToken))
            }
        case "play":
            isPlaying = true
            lastKnownTime = msg.time ?? lastKnownTime
            lastHeardAt = Date()
        case "pause":
            isPlaying = false
            lastKnownTime = msg.time ?? lastKnownTime
            lastHeardAt = Date()
        case "seek":
            isPlaying = msg.playing ?? isPlaying
            lastKnownTime = msg.time ?? lastKnownTime
            lastHeardAt = Date()
        case "tick":
            lastKnownTime = msg.time ?? lastKnownTime
            lastHeardAt = Date()
            isPlaying = true
        default:
            break
        }
    }
}
