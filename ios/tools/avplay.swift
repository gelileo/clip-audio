// Does playback actually need the 59s index walk, or did asking for .duration
// cause it? Measures time-to-first-audio WITHOUT loading duration.
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count > 1, let url = URL(string: args[1]) else { exit(1) }

func timeToAudio(_ label: String, loadDuration: Bool) async {
    let asset = AVURLAsset(url: url)
    let t0 = Date()
    if loadDuration {
        _ = try? await asset.load(.duration)
    }
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.play()
    var firstAudio: Double? = nil
    for _ in 0..<700 {                       // up to 70s
        if CMTimeGetSeconds(player.currentTime()) > 0.25 {
            firstAudio = Date().timeIntervalSince(t0); break
        }
        if item.status == .failed { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    player.pause()
    let d = item.duration
    let dur = d.isNumeric ? String(format: "%.1f", CMTimeGetSeconds(d)) : "indefinite"
    if let f = firstAudio {
        print(String(format: "%-28s first audio at %6.2fs   duration reported=%@",
                     (label as NSString).utf8String!, f, dur))
    } else {
        print(String(format: "%-28s NO AUDIO within 70s      status=%d",
                     (label as NSString).utf8String!, item.status.rawValue))
    }
}

await timeToAudio("play, no .duration load", loadDuration: false)
await timeToAudio("play, after .duration", loadDuration: true)
