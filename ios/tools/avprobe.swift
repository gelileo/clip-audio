// Fast AVFoundation strategy probe for macOS. AVFoundation's asset-loading
// behaviour is shared with iOS, so strategies can be triaged here in seconds
// instead of via simulator build/install/launch cycles.
// Usage: swift tools/avprobe.swift <url> [mime]
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count > 1, let url = URL(string: args[1]) else {
    print("usage: avprobe.swift <url> [mime]"); exit(1)
}
let mime: String? = args.count > 2 ? args[2] : nil

func probe(_ label: String, options: [String: Any]) async {
    let asset = AVURLAsset(url: url, options: options)
    let t0 = Date()
    do {
        let (playable, dur) = try await asset.load(.isPlayable, .duration)
        let tracks = try await asset.load(.tracks)
        var fmt = "none"
        if let a = tracks.first(where: { $0.mediaType == .audio }),
           let f = try await a.load(.formatDescriptions).first {
            let st = CMFormatDescriptionGetMediaSubType(f)
            let chars = [24, 16, 8, 0].map { String(UnicodeScalar(UInt8((st >> $0) & 0xFF))) }
            fmt = chars.joined()
        }
        let d = dur.isNumeric ? String(format: "%.1fs", CMTimeGetSeconds(dur)) : "indefinite"
        print(String(format: "%-26s load=%.2fs playable=%@ tracks=%d audio=%@ dur=%@",
                     (label as NSString).utf8String!, Date().timeIntervalSince(t0),
                     playable ? "YES" : "no", tracks.count, fmt, d))
    } catch {
        print(String(format: "%-26s load=%.2fs ERROR %@",
                     (label as NSString).utf8String!, Date().timeIntervalSince(t0),
                     String(describing: error).prefix(150).description))
    }
}

await probe("plain", options: [:])
await probe("mime=audio/mp4", options: ["AVURLAssetOutOfBandMIMETypeKey": "audio/mp4"])
await probe("mime=video/mp4", options: ["AVURLAssetOutOfBandMIMETypeKey": "video/mp4"])
if let m = mime { await probe("mime=\(m)", options: ["AVURLAssetOutOfBandMIMETypeKey": m]) }
