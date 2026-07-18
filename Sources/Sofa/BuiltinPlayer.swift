import AVFoundation
import AVKit
import Combine
import Foundation

/// Sofa's built-in player (AVPlayer) with sync: local play/pause/seek are
/// broadcast to the room; remote commands are applied with echo suppression.
@MainActor
final class BuiltinPlayer: ObservableObject {
    weak var state: AppState?

    let player = AVPlayer()
    @Published var hasMedia = false
    @Published var mediaName = ""

    private var suppressUntil = Date.distantPast
    private var lastKnownTime: Double = 0
    private var wasPlaying = false
    private var lastTickSent = Date.distantPast
    private var rateObservation: NSKeyValueObservation?
    private var timeJumpObserver: Any?
    private var periodicObserver: Any?

    init() {
        rateObservation = player.observe(\.rate, options: [.old, .new]) { [weak self] _, change in
            DispatchQueue.main.async {
                guard let self, let old = change.oldValue, let new = change.newValue else { return }
                let wasP = old > 0, isP = new > 0
                guard wasP != isP else { return }
                self.wasPlaying = isP
                guard Date() >= self.suppressUntil, self.hasMedia else { return }
                let t = self.player.currentTime().seconds
                self.state?.sync.send(SyncMessage(type: isP ? "play" : "pause", time: t))
            }
        }

        timeJumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main
        ) { [weak self] note in
            DispatchQueue.main.async {
                guard let self, self.hasMedia,
                      (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                let t = self.player.currentTime().seconds
                // Small jumps come from normal playback bookkeeping; only real seeks matter.
                guard abs(t - self.lastKnownTime) > 1.0 else { return }
                self.lastKnownTime = t
                guard Date() >= self.suppressUntil else { return }
                self.state?.sync.send(SyncMessage(type: "seek", time: t, playing: self.player.rate > 0))
            }
        }

        // Track time for seek detection + periodic drift ticks.
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastKnownTime = time.seconds
                // AVPlayer already gives us this callback while advancing. Use
                // it for drift ticks instead of waking a second timer for the
                // entire lifetime of this menu-bar app.
                let now = Date()
                guard self.hasMedia, self.player.rate > 0,
                      now.timeIntervalSince(self.lastTickSent) >= 5 else { return }
                self.lastTickSent = now
                self.state?.sync.send(SyncMessage(type: "tick", time: time.seconds))
            }
        }
    }

    // MARK: - Loading

    func load(url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        lastTickSent = Date()
        hasMedia = true
        mediaName = url.lastPathComponent
        state?.mediaActive = true
        state?.sync.send(SyncMessage(type: "loaded", name: mediaName))
    }

    func loadDemo() {
        if let url = Bundle.main.url(forResource: "demo", withExtension: "mp4") {
            load(url: url)
            mediaName = "Test video (built-in)"
            state?.showToast("Test video loaded — try play, pause and seeking")
        } else {
            state?.showToast("Demo video missing from the app bundle")
        }
    }

    func pauseAndUnload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        lastTickSent = .distantPast
        hasMedia = false
        mediaName = ""
    }

    func reset() {
        pauseAndUnload()
    }

    // MARK: - Remote commands

    func applyRemote(_ msg: SyncMessage) {
        guard hasMedia else { return }
        suppressUntil = Date().addingTimeInterval(1.0)
        let latency = msg.latencySeconds
        let time = msg.time ?? 0

        switch msg.type {
        case "play":
            seekIfNeeded(to: time + latency, threshold: 0.5)
            player.play()
        case "pause":
            player.pause()
            seekIfNeeded(to: time, threshold: 0.5)
        case "seek":
            seekIfNeeded(to: time + ((msg.playing ?? false) ? latency : 0), threshold: 0)
            if msg.playing ?? false { player.play() } else { player.pause() }
        case "tick":
            guard player.rate > 0 else { return }
            let target = time + latency
            if abs(player.currentTime().seconds - target) > 1.5 {
                seekIfNeeded(to: target, threshold: 0)
            }
        default:
            break
        }
    }

    private func seekIfNeeded(to target: Double, threshold: Double) {
        let current = player.currentTime().seconds
        guard threshold == 0 || abs(current - target) > threshold else { return }
        lastKnownTime = target
        player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
}
