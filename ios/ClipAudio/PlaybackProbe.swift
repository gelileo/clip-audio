import AVFoundation
import Foundation

/// M4's opening question, flagged at M0 as the largest untested assumption:
/// YouTube's itag 140 is an MP4 carrying the `dash` brand (`ftypdash`), and
/// its URL has no file extension. Will AVPlayer play it progressively?
///
/// Strategies run cheapest-first; there is no point building a resource
/// loader or localhost proxy if a simpler option already works.
enum PlaybackProbe {

    enum Strategy: String, CaseIterable {
        case plain    = "plain"     // AVURLAsset on the https URL, nothing else
        case mimeType = "mimeType"  // + out-of-band MIME, since the URL has no extension
    }

    static func probe(url: String,
                      headers: [String: String],
                      strategy: Strategy,
                      playSeconds: Double = 4.0) async -> [String: String] {
        var out: [String: String] = [:]
        guard let u = URL(string: url) else { out["error"] = "bad URL"; return out }

        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default)
            try s.setActive(true)
        } catch {
            out["audio_session"] = "FAILED: \(error.localizedDescription)"
        }

        var options: [String: Any] = [:]
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        if strategy == .mimeType {
            // The URL is a query string with no extension, so AVFoundation has
            // nothing to sniff a demuxer from. Tell it explicitly.
            options["AVURLAssetOutOfBandMIMETypeKey"] = "audio/mp4"
        }

        let asset = AVURLAsset(url: u, options: options)

        // Force the load and capture a real error. Polling AVPlayerItem.status
        // reports `.unknown` forever and explains nothing.
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            out["load_secs"] = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)
            out["is_playable"] = playable ? "true" : "false"
            out["duration"] = duration.isNumeric
                ? String(format: "%.1f", CMTimeGetSeconds(duration)) : "indefinite"
            let tracks = try await asset.load(.tracks)
            out["tracks"] = "\(tracks.count)"
            if let a = tracks.first(where: { $0.mediaType == .audio }) {
                let fmts = try await a.load(.formatDescriptions)
                out["audio_fmt"] = fmts.isEmpty ? "none"
                    : String(describing: CMFormatDescriptionGetMediaSubType(fmts[0]))
            }
        } catch {
            out["load_secs"] = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)
            out["load_error"] = String(describing: error).prefix(240).description
            return out
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.play()   // start loading AND playback; do not wait on .status first

        var ready = false
        for _ in 0..<100 {
            if item.status == .readyToPlay { ready = true; break }
            if item.status == .failed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        out["item_status"] = {
            switch item.status {
            case .readyToPlay: return "readyToPlay"
            case .failed:      return "failed"
            default:           return "unknown"
            }
        }()
        if let e = item.error { out["item_error"] = String(describing: e).prefix(200).description }
        guard ready else { out["playing"] = "false"; return out }

        let start = CMTimeGetSeconds(player.currentTime())
        try? await Task.sleep(nanoseconds: UInt64(playSeconds * 1_000_000_000))
        let end = CMTimeGetSeconds(player.currentTime())
        player.pause()

        let advanced = end - start
        out["advanced_secs"] = String(format: "%.2f", advanced)
        out["playing"] = advanced > 0.5 ? "true" : "false"
        out["keep_up"] = item.isPlaybackLikelyToKeepUp ? "true" : "false"
        if let log = item.errorLog()?.events.last {
            out["error_log"] = "\(log.errorStatusCode) \(log.errorComment ?? "")".prefix(140).description
        }
        return out
    }
}
