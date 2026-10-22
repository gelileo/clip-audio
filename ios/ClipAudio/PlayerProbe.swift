import Foundation
import MediaPlayer

/// Exercises the real AudioPlayer, not a standalone AVPlayer.
///
/// M4's earlier probe proved AVFoundation could play the stream. That is not
/// the same claim as "our player works" — the repeated lesson of this project
/// is to verify the component under test actually ran.
enum PlayerProbe {

    static func run(sourceURL: String, secondURL: String?) async -> [String: String] {
        var out: [String: String] = [:]
        let player = await AudioPlayer.shared

        let t0 = CFAbsoluteTimeGetCurrent()
        await MainActor.run {
            player.enqueue(sourceURL)
            if let s = secondURL { player.enqueue(s, playImmediately: false) }
        }

        // Time to first audio: resolve + attach + buffer, measured the way a
        // user experiences it (PRD §4 targets p50 <= 10s).
        var firstAudio: Double?
        for _ in 0..<400 {                                  // up to 40s
            let pos = await MainActor.run { player.position }
            if pos > 0.3 { firstAudio = CFAbsoluteTimeGetCurrent() - t0; break }
            let line = await MainActor.run { player.statusLine }
            if line.contains("No playable") || line.contains("Can't read")
                || line.contains("unavailable") || line.contains("format") {
                out["fail_reason"] = line; break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if let f = firstAudio {
            out["first_audio_secs"] = String(format: "%.2f", f)
        } else {
            out["first_audio_secs"] = "TIMEOUT"
            out["status_line"] = await MainActor.run { player.statusLine }
            return out
        }

        // Confirm the clock genuinely advances rather than reporting a stale value.
        let p1 = await MainActor.run { player.position }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let p2 = await MainActor.run { player.position }
        out["advanced_secs"] = String(format: "%.2f", p2 - p1)
        out["is_playing"] = await MainActor.run { player.isPlaying } ? "true" : "false"
        out["duration"] = String(format: "%.1f", await MainActor.run { player.duration })
        out["format"] = await MainActor.run { player.current?.formatID ?? "?" }

        // Lock-screen metadata (PRD §4: title and artwork must appear).
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        out["np_title"] = (info[MPMediaItemPropertyTitle] as? String).map {
            String($0.prefix(40)) } ?? "MISSING"
        out["np_artist"] = (info[MPMediaItemPropertyArtist] as? String)?.isEmpty == false ? "set" : "empty"
        out["np_duration"] = info[MPMediaItemPropertyPlaybackDuration] != nil ? "set" : "MISSING"
        out["np_artwork"] = info[MPMediaItemPropertyArtwork] != nil ? "set" : "pending"

        // Remote commands must be enabled or the lock screen is inert.
        let c = MPRemoteCommandCenter.shared()
        out["cmd_play"] = c.playCommand.isEnabled ? "on" : "off"
        out["cmd_next"] = c.nextTrackCommand.isEnabled ? "on" : "off"
        out["cmd_seek"] = c.changePlaybackPositionCommand.isEnabled ? "on" : "off"

        // Pre-resolution of the next item (PRD C9) — the thing that keeps a
        // queue gapless when the app is backgrounded.
        if secondURL != nil {
            var prefetched = false
            for _ in 0..<150 {                               // up to 15s
                let ready = await MainActor.run {
                    player.queue.count > 1 && player.queue[1].streamURL != nil
                }
                if ready { prefetched = true; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            out["prefetched_next"] = prefetched ? "true" : "false"
        }

        await MainActor.run { player.pause() }
        return out
    }
}
