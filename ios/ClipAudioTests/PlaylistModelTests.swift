import Testing
import Foundation
@testable import ClipAudio

@Suite("Playlist models")
struct PlaylistModelTests {

    @Test("PlaylistFile survives a Codable round-trip with order intact")
    func codableRoundTrip() throws {
        let items = [
            PlaylistItem(sourceURL: "https://example.com/a"),
            PlaylistItem(sourceURL: "https://example.com/b"),
        ]
        let file = PlaylistFile(
            schemaVersion: 1,
            playlists: [Playlist(name: "Favorites", isFavorites: true, items: items)])

        let data = try JSONEncoder().encode(file)
        let back = try JSONDecoder().decode(PlaylistFile.self, from: data)

        #expect(back.schemaVersion == 1)
        #expect(back.playlists.count == 1)
        #expect(back.playlists[0].name == "Favorites")
        #expect(back.playlists[0].isFavorites)
        #expect(back.playlists[0].items.map(\.sourceURL)
                == ["https://example.com/a", "https://example.com/b"])
    }

    @Test("A PlaylistItem built from a Track carries metadata but no stream URL")
    func trackConversionDropsStreamURL() throws {
        var t = Track(sourceURL: "https://youtube.com/watch?v=x")
        t.title = "Example"
        t.uploader = "Someone"
        t.duration = 120
        t.artworkURL = "https://img/x.jpg"
        t.streamURL = "https://googlevideo.com/SECRET"
        t.formatID = "234"
        t.resolvedAt = Date()

        let item = PlaylistItem(from: t)

        #expect(item.sourceURL == "https://youtube.com/watch?v=x")
        #expect(item.title == "Example")
        #expect(item.duration == 120)
        #expect(item.metadataFetchedAt != nil)   // metadata came with the track

        // PRD C8: the encoded form must not contain the stream URL anywhere.
        let json = String(data: try JSONEncoder().encode(item), encoding: .utf8)!
        #expect(!json.contains("SECRET"))
        #expect(!json.contains("googlevideo"))
    }

    @Test("A Track built from an item has metadata and no resolution yet")
    func itemConversionProducesUnresolvedTrack() {
        var item = PlaylistItem(sourceURL: "https://example.com/a")
        item.title = "Title"
        let t = Track(from: item)
        #expect(t.sourceURL == "https://example.com/a")
        #expect(t.title == "Title")
        #expect(t.streamURL == nil)
        #expect(t.isResolutionStale)   // never resolved
    }
}
