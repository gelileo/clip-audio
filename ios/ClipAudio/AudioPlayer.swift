import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Playback engine: queue, system audio session, lock-screen integration.
///
/// Holds source links, not stream URLs. A resolved URL is a short-lived
/// detail obtained just before it is needed (PRD C8).
@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var statusLine = "Idle"
    @Published private(set) var isBuffering = false

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let source: StreamSource = YtDlpStreamSource()
    private let player = AVQueuePlayer()
    private var timeObserver: Any?
    private var itemObservers: [NSKeyValueObservation] = []
    private var artworkTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var recovering = false

    private override init() {
        super.init()
        configureSession()
        configureRemoteCommands()
        observeTime()
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemStalled(_:)),
            name: .AVPlayerItemPlaybackStalled, object: nil)
    }

    // MARK: - System integration

    private func configureSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            // .playback is what permits audio to continue with the screen
            // locked; paired with the `audio` background mode in Info.plist.
            try s.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try s.setActive(true)
        } catch {
            statusLine = "Audio session failed: \(error.localizedDescription)"
        }
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in guard let s = self else { return }; s.seek(to: s.position + 30) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in guard let s = self else { return }; s.seek(to: max(0, s.position - 15)) }
            return .success
        }
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration, d.isNumeric {
                    self.duration = CMTimeGetSeconds(d)
                }
                self.isPlaying = self.player.timeControlStatus == .playing
                self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.refreshNowPlayingTime()
            }
        }
    }

    // MARK: - Queue

    func enqueue(_ sourceURL: String, playImmediately: Bool = true) {
        let t = Track(sourceURL: sourceURL)
        queue.append(t)
        if playImmediately && queue.count == 1 {
            index = 0
            Task { await startCurrent() }
        } else if playImmediately {
            index = queue.count - 1
            Task { await startCurrent() }
        }
    }

    func next() {
        guard index + 1 < queue.count else { return }
        index += 1
        Task { await startCurrent() }
    }

    func previous() {
        // Restart the track first, as most players do, before stepping back.
        if position > 3 { seek(to: 0); return }
        guard index > 0 else { seek(to: 0); return }
        index -= 1
        Task { await startCurrent() }
    }

    // MARK: - Playback

    private func startCurrent() async {
        guard var track = current else { return }
        statusLine = "Resolving…"
        isBuffering = true
        do {
            if track.streamURL == nil || track.isResolutionStale {
                track = try await source.resolve(track.sourceURL)
                if queue.indices.contains(index) { queue[index] = track }
            }
            guard let s = track.streamURL, let url = URL(string: s) else {
                statusLine = "No playable stream"; isBuffering = false; return
            }
            attach(url: url, track: track)
            player.play()
            statusLine = track.formatID.map { "Playing · \($0)" } ?? "Playing"
            prefetchNext()
        } catch let e as YtDlpStreamSource.ResolveError {
            statusLine = e.userMessage
            isBuffering = false
        } catch {
            statusLine = error.localizedDescription
            isBuffering = false
        }
    }

    private func attach(url: URL, track: Track) {
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()

        let item = AVPlayerItem(url: url)
        itemObservers.append(item.observe(\.status) { [weak self] it, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if it.status == .failed {
                    self.statusLine = "Stream rejected — retrying"
                    self.recoverFromFailure()
                }
            }
        })
        itemObservers.append(item.observe(\.isPlaybackLikelyToKeepUp) { [weak self] it, _ in
            MainActor.assumeIsolated { self?.isBuffering = !it.isPlaybackLikelyToKeepUp }
        })

        player.removeAllItems()
        player.insert(item, after: nil)
        duration = track.duration ?? 0
        updateNowPlaying(track)
    }

    func play()   { player.play();  isPlaying = true;  refreshNowPlayingTime() }
    func pause()  { player.pause(); isPlaying = false; refreshNowPlayingTime() }
    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.refreshNowPlayingTime() }
        }
    }

    // MARK: - Resilience

    /// A resolved URL can expire or be rejected mid-session. Re-resolve once
    /// before surfacing an error (PRD §10 degradation ladder).
    private func recoverFromFailure() {
        guard !recovering, var track = current else { return }
        recovering = true
        Task {
            defer { recovering = false }
            track.streamURL = nil
            track.resolvedAt = nil
            if queue.indices.contains(index) { queue[index] = track }
            await startCurrent()
        }
    }

    @objc private func itemStalled(_ n: Notification) {
        Task { @MainActor in
            isBuffering = true
            statusLine = "Buffering…"
        }
    }

    @objc private func itemDidEnd(_ n: Notification) {
        Task { @MainActor in
            if index + 1 < queue.count { next() }
            else { isPlaying = false; statusLine = "Finished" }
        }
    }

    /// Resolve the next track while the current one plays.
    ///
    /// Background audio keeps the app alive only while audio is playing, so a
    /// resolve started at track-end is likely to be suspended (PRD C9).
    private func prefetchNext() {
        prefetchTask?.cancel()
        let n = index + 1
        guard queue.indices.contains(n), queue[n].streamURL == nil else { return }
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            if let resolved = try? await self.source.resolve(self.queue[n].sourceURL) {
                await MainActor.run {
                    if self.queue.indices.contains(n) { self.queue[n] = resolved }
                }
            }
        }
    }

    // MARK: - Lock screen

    private func updateNowPlaying(_ track: Track) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.uploader ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: player.rate,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
        ]
        if let d = track.duration { info[MPMediaItemPropertyPlaybackDuration] = d }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask?.cancel()
        guard let s = track.artworkURL, let url = URL(string: s) else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            await MainActor.run {
                guard self != nil else { return }
                var i = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                i[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = i
            }
        }
    }

    private func refreshNowPlayingTime() {
        guard var i = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        i[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        i[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        if duration > 0 { i[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = i
    }
}
