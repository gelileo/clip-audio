import Testing
import Foundation
@testable import ClipAudio

@Suite("Playlist row state")
struct PlaylistRowStateTests {
    private func item(attempts: Int = 0, fetched: Bool = false, unavailable: Bool = false) -> PlaylistItem {
        var i = PlaylistItem(sourceURL: "https://example.com/a")
        i.metadataAttempts = attempts
        i.metadataFetchedAt = fetched ? Date() : nil
        i.unavailable = unavailable
        return i
    }

    @Test("Fresh item is loading")
    func loading() { #expect(PlaylistRowState.state(for: item(attempts: 1)) == .loading) }

    @Test("Item at the attempt cap offers retry")
    func capped() {
        let n = MetadataBackfiller.maxMetadataAttempts
        #expect(PlaylistRowState.state(for: item(attempts: n)) == .retryable(unavailable: false))
    }

    @Test("Unavailable item offers retry even below the cap")
    func unavailable() {
        #expect(PlaylistRowState.state(for: item(attempts: 0, unavailable: true)) == .retryable(unavailable: true))
    }

    @Test("Item with metadata is ready")
    func ready() { #expect(PlaylistRowState.state(for: item(fetched: true)) == .ready) }

    @Test("Read-only disables editing; empty playlist cannot play all")
    func editing() {
        #expect(!PlaylistEditing.canEdit(isReadOnly: true))
        #expect(PlaylistEditing.canEdit(isReadOnly: false))
        #expect(!PlaylistEditing.canPlayAll(Playlist(name: "x")))
        #expect(!PlaylistEditing.canPlayAll(nil))
        #expect(PlaylistEditing.canPlayAll(Playlist(name: "x", items: [item()])))
    }
}
