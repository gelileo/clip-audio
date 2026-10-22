import Testing
import Foundation
@testable import ClipAudio

/// Controllable stand-in for the real yt-dlp resolver.
private struct StubSource: StreamSource {
    enum Behavior { case succeed, fail, empty }
    let behavior: Behavior
    func resolve(_ sourceURL: String) async throws -> Track {
        switch behavior {
        case .fail:
            throw YtDlpStreamSource.ResolveError(stage: "EXTRACT", detail: "nope")
        case .empty:
            return Track(sourceURL: sourceURL)   // resolved, but no metadata at all
        case .succeed:
            var t = Track(sourceURL: sourceURL)
            t.title = "Resolved \(sourceURL.suffix(1))"
            t.uploader = "Uploader"
            t.duration = 42
            t.artworkURL = "https://img/x.jpg"
            t.streamURL = "https://googlevideo.com/SECRET"   // must not be stored
            return t
        }
    }
}

@MainActor
@Suite("MetadataBackfiller")
struct MetadataBackfillerTests {

    private func makeStore() throws -> PlaylistStore {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("plbf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return PlaylistStore(storage: PlaylistStorage(directory: d),
                             saveDebounce: .milliseconds(50))
    }

    @Test("A successful resolve applies metadata and never stores the stream URL")
    func successAppliesMetadata() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        _ = store.add(sourceURL: "https://x/1", to: p.id)

        await MetadataBackfiller(store: store, source: StubSource(behavior: .succeed)).runOnce()

        let item = store.playlists.first { $0.id == p.id }!.items[0]
        #expect(item.title == "Resolved 1")
        #expect(item.duration == 42)
        #expect(item.hasMetadata)

        // PRD C8 guard, automated.
        let json = String(data: try JSONEncoder().encode(store.playlists), encoding: .utf8)!
        #expect(!json.contains("SECRET"))
    }

    @Test("Failures increment attempts and stop at the limit")
    func failureStopsAfterLimit() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        _ = store.add(sourceURL: "https://x/1", to: p.id)
        let bf = MetadataBackfiller(store: store, source: StubSource(behavior: .fail))

        for _ in 0..<5 { await bf.runOnce() }

        let item = store.playlists.first { $0.id == p.id }!.items[0]
        #expect(item.metadataAttempts == MetadataBackfiller.maxMetadataAttempts)
        #expect(!item.hasMetadata)
        #expect(store.itemsNeedingMetadata(limit: 10).isEmpty)
    }

    @Test("A resolve that yields no metadata counts as a failed attempt, not success")
    func emptyResolveIsFailure() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        _ = store.add(sourceURL: "https://x/1", to: p.id)
        let bf = MetadataBackfiller(store: store, source: StubSource(behavior: .empty))

        await bf.runOnce()
        var item = store.playlists.first { $0.id == p.id }!.items[0]
        #expect(!item.hasMetadata)
        #expect(item.metadataAttempts == 1)
        #expect(store.itemsNeedingMetadata(limit: 10).count == 1)   // still retryable

        for _ in 0..<5 { await bf.runOnce() }
        item = store.playlists.first { $0.id == p.id }!.items[0]
        #expect(item.metadataAttempts == MetadataBackfiller.maxMetadataAttempts)
        #expect(store.itemsNeedingMetadata(limit: 10).isEmpty)
    }

    // Review Focus #4
    @Test("Metadata arriving for a deleted item is a no-op")
    func writeBackForDeletedItemIsSafe() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        guard case let .added(item)? = store.add(sourceURL: "https://x/1", to: p.id) else {
            Issue.record("expected .added"); return
        }
        store.remove(itemID: item.id, from: p.id)

        store.applyMetadata(
            ResolvedMetadata(title: "Ghost", uploader: nil, duration: nil, artworkURL: nil),
            toItemID: item.id, in: p.id)

        #expect(store.playlists.first { $0.id == p.id }!.items.isEmpty)
    }

    @Test("Items that already have metadata are not re-resolved")
    func skipsItemsWithMetadata() async throws {
        let store = try makeStore()
        var t = Track(sourceURL: "https://x/1")
        t.title = "Already known"
        _ = store.toggleFavorite(sourceURL: t.sourceURL, metadataFrom: t)

        await MetadataBackfiller(store: store, source: StubSource(behavior: .succeed)).runOnce()

        #expect(store.favorites.items[0].title == "Already known")
    }

    @Test("start() drains the queue and then stops itself")
    func startDrainsQueue() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        for i in 1...3 { _ = store.add(sourceURL: "https://x/\(i)", to: p.id) }
        let bf = MetadataBackfiller(store: store, source: StubSource(behavior: .succeed))

        bf.start()
        for _ in 0..<40 where !store.itemsNeedingMetadata(limit: 1).isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        bf.stop()

        let items = store.playlists.first { $0.id == p.id }!.items
        #expect(items.allSatisfy { $0.hasMetadata })
    }
}
