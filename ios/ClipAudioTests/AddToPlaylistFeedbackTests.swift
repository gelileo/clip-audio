import Testing
import Foundation
@testable import ClipAudio

@Suite("Add to playlist feedback")
struct AddToPlaylistFeedbackTests {
    private let item = PlaylistItem(sourceURL: "https://example.com/a")

    @Test("Added dismisses silently")
    func added() { #expect(AddToPlaylistFeedback.message(for: .added(item), playlistName: "Mix") == nil) }

    @Test("Already present names the playlist")
    func present() {
        #expect(AddToPlaylistFeedback.message(for: .alreadyPresent(item), playlistName: "Mix") == "Already in Mix")
    }

    @Test("Failed add reports it")
    func failed() { #expect(AddToPlaylistFeedback.message(for: nil, playlistName: "Mix") == "Couldn't add that") }

    @Test("Heart label follows state")
    func heart() {
        #expect(AddToPlaylistFeedback.heartLabel(isFavorited: true) == "Remove from Favorites")
        #expect(AddToPlaylistFeedback.heartLabel(isFavorited: false) == "Add to Favorites")
    }
}
