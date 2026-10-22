import Testing
import Foundation
@testable import ClipAudio

@MainActor
@Suite("AudioPlayer + playlists")
struct AudioPlayerPlaylistTests {

    @Test("Playing a playlist replaces the queue and sets the context")
    func playlistReplacesQueue() {
        let player = AudioPlayer.shared
        player.resetForTesting()
        player.appendForTesting(sourceURL: "https://old/0")   // must be replaced

        let list = Playlist(name: "Focus", items: [
            PlaylistItem(sourceURL: "https://x/1"),
            PlaylistItem(sourceURL: "https://x/2"),
            PlaylistItem(sourceURL: "https://x/3"),
        ])
        player.loadQueue(from: list, startingAt: 1)

        #expect(player.queue.map(\.sourceURL) == ["https://x/1", "https://x/2", "https://x/3"])
        #expect(player.index == 1)
        #expect(player.playbackContext == "Focus")
    }

    @Test("Start index is clamped into range")
    func startIndexClamped() {
        let player = AudioPlayer.shared
        player.resetForTesting()
        let list = Playlist(name: "Focus", items: [
            PlaylistItem(sourceURL: "https://x/1"),
            PlaylistItem(sourceURL: "https://x/2"),
        ])
        player.loadQueue(from: list, startingAt: 99)
        #expect(player.index == 1)
        player.loadQueue(from: list, startingAt: -5)
        #expect(player.index == 0)
    }

    @Test("An ad-hoc link clears the playlist context")
    func adHocClearsContext() {
        let player = AudioPlayer.shared
        player.resetForTesting()
        player.loadQueue(from: Playlist(name: "Focus",
                                        items: [PlaylistItem(sourceURL: "https://x/1")]),
                         startingAt: 0)
        #expect(player.playbackContext == "Focus")

        player.appendForTesting(sourceURL: "https://y/9")
        #expect(player.playbackContext == nil)
    }

    @Test("The real enqueue path clears the playlist context")
    func enqueueClearsContext() {
        let player = AudioPlayer.shared
        player.resetForTesting()
        player.loadQueue(from: Playlist(name: "Focus",
                                        items: [PlaylistItem(sourceURL: "https://x/1")]),
                         startingAt: 0)
        #expect(player.playbackContext == "Focus")

        player.enqueue("https://y/9", playImmediately: false)
        #expect(player.playbackContext == nil)
    }

    // The queue holds copies, so deleting from the library must not disturb
    // what is playing.
    @Test("Queue is unaffected by later edits to the source playlist")
    func queueIsACopy() {
        let player = AudioPlayer.shared
        player.resetForTesting()
        var list = Playlist(name: "Focus", items: [
            PlaylistItem(sourceURL: "https://x/1"),
            PlaylistItem(sourceURL: "https://x/2"),
        ])
        player.loadQueue(from: list, startingAt: 0)

        list.items.removeAll()
        list.items.append(PlaylistItem(sourceURL: "https://z/other"))
        #expect(player.queue.map(\.sourceURL) == ["https://x/1", "https://x/2"])
        #expect(player.index == 0)
    }
}
