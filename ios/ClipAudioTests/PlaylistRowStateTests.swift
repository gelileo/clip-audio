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

    @Test("Metadata present at or past the cap is ready, not retryable")
    func readyBeatsCap() {
        let n = MetadataBackfiller.maxMetadataAttempts
        #expect(PlaylistRowState.state(for: item(attempts: n, fetched: true)) == .ready)
        #expect(PlaylistRowState.state(for: item(attempts: n + 5, fetched: true)) == .ready)
    }

    @Test("Unavailable wins over present metadata")
    func unavailableBeatsMetadata() {
        #expect(PlaylistRowState.state(for: item(fetched: true, unavailable: true))
                == .retryable(unavailable: true))
    }

    @Test("Attempts strictly above the cap are retryable")
    func aboveCap() {
        let n = MetadataBackfiller.maxMetadataAttempts
        #expect(PlaylistRowState.state(for: item(attempts: n + 1)) == .retryable(unavailable: false))
        #expect(PlaylistRowState.state(for: item(attempts: n - 1)) == .loading)
    }

    @Test("Blank and whitespace-only names cannot be submitted")
    func nameSubmission() {
        #expect(!PlaylistEditing.canSubmit(name: ""))
        #expect(!PlaylistEditing.canSubmit(name: "  \n\t "))
        #expect(PlaylistEditing.canSubmit(name: " Road trip "))
    }

    @Test("Empty or missing playlist cannot play all")
    func playAll() {
        #expect(!PlaylistEditing.canPlayAll(Playlist(name: "x")))
        #expect(!PlaylistEditing.canPlayAll(nil))
        #expect(PlaylistEditing.canPlayAll(Playlist(name: "x", items: [item()])))
    }
}
