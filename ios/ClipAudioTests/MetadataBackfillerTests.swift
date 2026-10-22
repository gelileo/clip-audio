import Testing
import Foundation
@testable import ClipAudio

/// Thread-safe call counter for stubs that run off the main actor.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return calls }
}

/// Controllable stand-in for the real yt-dlp resolver.
private struct StubSource: StreamSource {
    enum Behavior { case succeed, fail, empty, uploaderOnly, blankTitle, gone }
    let behavior: Behavior
    var delay: Duration? = nil          // cancellable, like a real network wait
    var log: CallLog? = nil

    func resolve(_ sourceURL: String) async throws -> Track {
        log?.record(sourceURL)
        if let delay { try await Task.sleep(for: delay) }
        switch behavior {
        case .fail:
            throw YtDlpStreamSource.ResolveError(stage: "EXTRACT", detail: "nope")
        case .gone:
            throw YtDlpStreamSource.ResolveError(stage: "EXTRACT", detail: "Video unavailable")
        case .empty:
            return Track(sourceURL: sourceURL)   // resolved, but no metadata at all
        case .uploaderOnly:
            var t = Track(sourceURL: sourceURL)
            t.uploader = "Someone"
            t.duration = 10
            return t
        case .blankTitle:
            var t = Track(sourceURL: sourceURL)
            t.title = "  \n "
            return t
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

    private func items(_ store: PlaylistStore, _ p: Playlist) -> [PlaylistItem] {
        store.playlists.first { $0.id == p.id }!.items
    }

    private func waitUntil(_ cond: () -> Bool) async throws {
        for _ in 0..<100 where !cond() { try await Task.sleep(for: .milliseconds(30)) }
    }

    @Test("start() drains the queue")
    func startDrainsQueue() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        for i in 1...3 { _ = store.add(sourceURL: "https://x/\(i)", to: p.id) }
        let bf = MetadataBackfiller(store: store, source: StubSource(behavior: .succeed))

        bf.start()
        try await waitUntil { store.itemsNeedingMetadata(limit: 1).isEmpty }
        bf.stop()

        #expect(items(store, p).allSatisfy { $0.hasMetadata })
    }

    @Test("start() is idempotent while a loop is running")
    func startIdempotent() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        for i in 1...3 { _ = store.add(sourceURL: "https://x/\(i)", to: p.id) }
        let log = CallLog()
        let bf = MetadataBackfiller(
            store: store, source: StubSource(behavior: .succeed, delay: .milliseconds(30), log: log))

        bf.start(); bf.start(); bf.start()
        #expect(bf.isRunning)
        try await waitUntil { store.itemsNeedingMetadata(limit: 1).isEmpty }
        #expect(log.all.count == 3)       // each item resolved exactly once
        try await waitUntil { !bf.isRunning }
        #expect(!bf.isRunning)            // drained loop releases its handle
    }

    @Test("stop() halts the loop and does not burn attempts")
    func stopHaltsWithoutBurningAttempts() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        for i in 1...6 { _ = store.add(sourceURL: "https://x/\(i)", to: p.id) }
        let log = CallLog()
        let bf = MetadataBackfiller(
            store: store, source: StubSource(behavior: .succeed, delay: .milliseconds(200), log: log))

        bf.start()
        try await Task.sleep(for: .milliseconds(60))   // first batch in flight
        bf.stop()
        #expect(!bf.isRunning)
        try await Task.sleep(for: .milliseconds(700))

        #expect(log.all.count == 2)                    // nothing started after stop
        #expect(items(store, p).allSatisfy { $0.metadataAttempts == 0 })
        #expect(items(store, p).allSatisfy { !$0.hasMetadata })
    }

    @Test("stop() then start() keeps exactly one tracked loop")
    func restartAfterStop() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        for i in 1...4 { _ = store.add(sourceURL: "https://x/\(i)", to: p.id) }
        let bf = MetadataBackfiller(
            store: store, source: StubSource(behavior: .succeed, delay: .milliseconds(100)))

        bf.start()
        try await Task.sleep(for: .milliseconds(30))
        bf.stop()
        bf.start()                                     // old loop still unwinding
        #expect(bf.isRunning)
        try await Task.sleep(for: .milliseconds(300))  // old loop has finished by now
        #expect(bf.isRunning)                          // new loop's handle not erased
        bf.stop()
        #expect(!bf.isRunning)
        #expect(items(store, p).allSatisfy { $0.metadataAttempts == 0 })
    }

    @Test("Overlapping runOnce calls do not resolve or count an item twice")
    func runOnceIsReentrant() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        _ = store.add(sourceURL: "https://x/1", to: p.id)
        let log = CallLog()
        let bf = MetadataBackfiller(
            store: store, source: StubSource(behavior: .fail, delay: .milliseconds(100), log: log))

        async let a: Void = bf.runOnce()
        async let b: Void = bf.runOnce()
        _ = await (a, b)

        #expect(log.all.count == 1)
        #expect(items(store, p)[0].metadataAttempts == 1)
    }

    @Test("A definitive failure marks the item unavailable instead of burning attempts")
    func definitiveFailureMarksUnavailable() async throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        _ = store.add(sourceURL: "https://x/1", to: p.id)

        await MetadataBackfiller(store: store, source: StubSource(behavior: .gone)).runOnce()

        let item = items(store, p)[0]
        #expect(item.unavailable)
        #expect(item.metadataAttempts == 0)
        #expect(!item.hasMetadata)
        #expect(store.itemsNeedingMetadata(limit: 10).isEmpty)
    }

    @Test("ResolveError.isDefinitive is true only for gone/blocked, not transient errors")
    func isDefinitiveClassification() {
        func e(_ stage: String, _ d: String) -> YtDlpStreamSource.ResolveError {
            .init(stage: stage, detail: d)
        }
        #expect(e("EXTRACT", "Video unavailable").isDefinitive)
        #expect(e("EXTRACT", "This video is private").isDefinitive)
        #expect(e("EXTRACT", "geo restricted").isDefinitive)
        #expect(!e("EXTRACT", "timed out").isDefinitive)
        #expect(!e("BRIDGE", "boom").isDefinitive)
        #expect(!e("NO_COMPATIBLE_FORMAT", "x").isDefinitive)
        #expect(!e("EXTRACT", "something odd").isDefinitive)
        // False positives that would permanently hide a healthy item.
        #expect(!e("EXTRACT", "HTTP Error 503: Service Unavailable").isDefinitive)
        #expect(!e("EXTRACT", "HTTP Error 500: Internal Server Error").isDefinitive)
        #expect(!e("EXTRACT", "The read operation timed out").isDefinitive)
        #expect(!e("EXTRACT", "<urlopen error [Errno 8] nodename nor servname>").isDefinitive)
        #expect(!e("EXTRACT", "Unable to download webpage: Network is unavailable").isDefinitive)
        #expect(!e("EXTRACT", "geo lookup failed").isDefinitive)
    }

    @Test("A resolve without a usable title is a failed attempt, even with other fields")
    func titlelessResolveIsFailure() async throws {
        for behavior in [StubSource.Behavior.uploaderOnly, .blankTitle] {
            let store = try makeStore()
            let p = try store.createPlaylist(name: "Focus")
            _ = store.add(sourceURL: "https://x/1", to: p.id)
            await MetadataBackfiller(store: store, source: StubSource(behavior: behavior)).runOnce()
            let item = items(store, p)[0]
            #expect(!item.hasMetadata)
            #expect(item.metadataAttempts == 1)
            #expect(item.uploader == nil)     // nothing half-applied
        }
    }

    @Test("apply/applyMetadata refuse a titleless value for every caller")
    func applyGuardHoldsForAllCallers() throws {
        var item = PlaylistItem(sourceURL: "https://x/1")
        let r1 = item.apply(ResolvedMetadata(title: nil, uploader: "U", duration: 1, artworkURL: nil))
        let r2 = item.apply(ResolvedMetadata(title: "   ", uploader: nil, duration: nil, artworkURL: nil))
        #expect(!r1)
        #expect(!r2)
        #expect(!item.hasMetadata)

        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        guard case let .added(added)? = store.add(sourceURL: "https://x/2", to: p.id) else {
            Issue.record("expected .added"); return
        }
        let ok = store.applyMetadata(
            ResolvedMetadata(title: nil, uploader: nil, duration: nil, artworkURL: nil),
            toItemID: added.id, in: p.id)
        #expect(!ok)
        #expect(!items(store, p)[0].hasMetadata)
    }

    @Test("Favouriting a track with a blank title does not mark it fetched")
    func blankTitleTrackNotFetched() {
        for title in ["", "  \n "] {
            var t = Track(sourceURL: "https://x/1")
            t.title = title
            #expect(!PlaylistItem(from: t).hasMetadata)
        }
        var ok = Track(sourceURL: "https://x/1")
        ok.title = "Real"
        #expect(PlaylistItem(from: ok).hasMetadata)
    }

    @Test("retryMetadata clears unavailable and zeroes attempts")
    func retryClearsUnavailable() throws {
        let store = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        guard case let .added(item)? = store.add(sourceURL: "https://x/1", to: p.id) else {
            Issue.record("expected .added"); return
        }
        store.recordMetadataFailure(itemID: item.id, in: p.id)
        store.markUnavailable(itemID: item.id, in: p.id)
        #expect(store.itemsNeedingMetadata(limit: 10).isEmpty)

        store.retryMetadata(itemID: item.id, in: p.id)

        let after = items(store, p)[0]
        #expect(!after.unavailable)
        #expect(after.metadataAttempts == 0)
        #expect(store.itemsNeedingMetadata(limit: 10).count == 1)
    }
}
