import Testing
import Foundation
@testable import ClipAudio

@MainActor
@Suite("PlaylistStore")
struct PlaylistStoreTests {

    private func makeStore() throws -> (PlaylistStore, URL) {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("plstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return (PlaylistStore(storage: PlaylistStorage(directory: d)), d)
    }

    @Test("Favorites exists at index 0 on a fresh store")
    func favoritesSeeded() throws {
        let (store, _) = try makeStore()
        #expect(store.playlists.count == 1)
        #expect(store.playlists[0].isFavorites)
        #expect(store.favorites.name == "Favorites")
    }

    @Test("Favorites cannot be renamed or deleted")
    func favoritesImmutable() throws {
        let (store, _) = try makeStore()
        let id = store.favorites.id
        #expect(throws: PlaylistStore.StoreError.favoritesImmutable) {
            try store.renamePlaylist(id: id, to: "Nope")
        }
        #expect(throws: PlaylistStore.StoreError.favoritesImmutable) {
            try store.deletePlaylist(id: id)
        }
        #expect(store.playlists.count == 1)
    }

    // Review Focus #1
    @Test("Blank and whitespace-only names are rejected")
    func blankNamesRejected() throws {
        let (store, _) = try makeStore()
        #expect(throws: PlaylistStore.StoreError.blankName) { _ = try store.createPlaylist(name: "") }
        #expect(throws: PlaylistStore.StoreError.blankName) { _ = try store.createPlaylist(name: "   ") }
        let p = try store.createPlaylist(name: "Focus")
        #expect(throws: PlaylistStore.StoreError.blankName) {
            try store.renamePlaylist(id: p.id, to: " \n ")
        }
        #expect(store.playlists.count == 2)
    }

    // Review Focus #5
    @Test("Duplicate playlist names are allowed and stay independently addressable")
    func duplicateNamesAllowed() throws {
        let (store, _) = try makeStore()
        let a = try store.createPlaylist(name: "Mix")
        let b = try store.createPlaylist(name: "Mix")
        #expect(a.id != b.id)
        _ = store.add(sourceURL: "https://x/1", to: a.id)
        #expect(store.playlists.first { $0.id == a.id }?.items.count == 1)
        #expect(store.playlists.first { $0.id == b.id }?.items.isEmpty == true)
    }

    @Test("Adding the same URL twice to one playlist is a no-op")
    func dedupeWithinPlaylist() throws {
        let (store, _) = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        let first = store.add(sourceURL: "https://x/1", to: p.id)
        let second = store.add(sourceURL: "https://x/1", to: p.id)
        guard case .added = first else { Issue.record("expected .added"); return }
        guard case .alreadyPresent = second else { Issue.record("expected .alreadyPresent"); return }
        #expect(store.playlists.first { $0.id == p.id }?.items.count == 1)
    }

    @Test("The same URL may live in two playlists as independent rows")
    func sameURLAcrossPlaylists() throws {
        let (store, _) = try makeStore()
        let a = try store.createPlaylist(name: "A")
        let b = try store.createPlaylist(name: "B")
        _ = store.add(sourceURL: "https://x/1", to: a.id)
        _ = store.add(sourceURL: "https://x/1", to: b.id)
        let ia = store.playlists.first { $0.id == a.id }!.items[0]
        let ib = store.playlists.first { $0.id == b.id }!.items[0]
        #expect(ia.id != ib.id)

        store.markUnavailable(itemID: ia.id, in: a.id)
        #expect(store.playlists.first { $0.id == a.id }!.items[0].unavailable)
        #expect(!store.playlists.first { $0.id == b.id }!.items[0].unavailable)
    }

    @Test("toggleFavorite adds then removes, reporting the new state")
    func heartToggles() throws {
        let (store, _) = try makeStore()
        #expect(!store.isFavorited(sourceURL: "https://x/1"))
        #expect(store.toggleFavorite(sourceURL: "https://x/1", metadataFrom: nil))
        #expect(store.isFavorited(sourceURL: "https://x/1"))
        #expect(!store.toggleFavorite(sourceURL: "https://x/1", metadataFrom: nil))
        #expect(!store.isFavorited(sourceURL: "https://x/1"))
        #expect(store.favorites.items.isEmpty)
    }

    @Test("Hearting the playing track stores metadata so backfill skips it")
    func heartWithTrackMetadata() throws {
        let (store, _) = try makeStore()
        var t = Track(sourceURL: "https://x/1")
        t.title = "Known title"
        _ = store.toggleFavorite(sourceURL: t.sourceURL, metadataFrom: t)
        let item = store.favorites.items[0]
        #expect(item.title == "Known title")
        #expect(item.hasMetadata)
        #expect(store.itemsNeedingMetadata(limit: 10).isEmpty)
    }

    @Test("Favorites stays at index 0 after reordering user playlists")
    func favoritesStaysPinned() throws {
        let (store, _) = try makeStore()
        _ = try store.createPlaylist(name: "A")
        _ = try store.createPlaylist(name: "B")
        store.movePlaylists(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        #expect(store.playlists[0].isFavorites)
        #expect(store.playlists.map(\.name) == ["Favorites", "B", "A"])
    }

    @Test("Item order persists across a reload")
    func orderPersists() throws {
        let (store, dir) = try makeStore()
        let p = try store.createPlaylist(name: "Focus")
        for i in 1...3 { _ = store.add(sourceURL: "https://x/\(i)", to: p.id) }
        store.moveItems(in: p.id, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        store.flush()

        let reloaded = PlaylistStore(storage: PlaylistStorage(directory: dir))
        let items = reloaded.playlists.first { $0.name == "Focus" }!.items
        #expect(items.map(\.sourceURL) == ["https://x/3", "https://x/1", "https://x/2"])
    }

    // MARK: - Never write over data we could not read

    private func freshDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("plstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("Newer-schema file loads read-only and is never overwritten")
    func newerSchemaNeverClobbered() throws {
        let d = try freshDir()
        let url = d.appendingPathComponent("playlists.json")
        let json = #"{"schemaVersion":2,"playlists":[{"id":"\#(UUID().uuidString)","name":"Future","isFavorites":false,"items":[],"createdAt":0}]}"#
        try Data(json.utf8).write(to: url)
        let store = PlaylistStore(storage: PlaylistStorage(directory: d))
        #expect(store.isReadOnly)
        #expect(store.statusMessage != nil)
        #expect(store.playlists.contains { $0.name == "Future" })
        _ = try? store.createPlaylist(name: "X")
        store.flush()
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }

    @Test("Unreadable (IO error) library is read-only, seeded in memory, untouched")
    func unreadableIOError() throws {
        let d = try freshDir()
        // A directory where the file should be: reading it throws, it is not corruption.
        let url = d.appendingPathComponent("playlists.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = PlaylistStore(storage: PlaylistStorage(directory: d))
        #expect(store.isReadOnly)
        #expect(store.statusMessage != nil)
        #expect(store.playlists.count == 1 && store.playlists[0].isFavorites)
        _ = store.toggleFavorite(sourceURL: "https://x/1", metadataFrom: nil)
        store.flush()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test("Newer-schema file we cannot decode is read-only and untouched")
    func newerUndecodable() throws {
        let d = try freshDir()
        let url = d.appendingPathComponent("playlists.json")
        let json = #"{"schemaVersion":99,"playlists":"weird"}"#
        try Data(json.utf8).write(to: url)
        let store = PlaylistStore(storage: PlaylistStorage(directory: d))
        #expect(store.isReadOnly)
        #expect(store.statusMessage != nil)
        #expect(store.playlists.count == 1 && store.playlists[0].isFavorites)
        store.flush()
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }

    @Test("Corrupt file is quarantined, store is writable and tells the user")
    func corruptRecovered() throws {
        let d = try freshDir()
        try Data("not json".utf8).write(to: d.appendingPathComponent("playlists.json"))
        let store = PlaylistStore(storage: PlaylistStorage(directory: d))
        #expect(!store.isReadOnly)
        #expect(store.statusMessage?.contains("playlists.corrupt-") == true)
    }

    @Test("Exhausted or unavailable items are not offered for backfill")
    func backfillLimits() throws {
        let (store, _) = try makeStore()
        let p = try store.createPlaylist(name: "P")
        guard case let .added(a)? = store.add(sourceURL: "https://x/a", to: p.id),
              case let .added(b)? = store.add(sourceURL: "https://x/b", to: p.id)
        else { Issue.record("expected .added"); return }
        #expect(store.itemsNeedingMetadata(limit: 10).count == 2)
        for _ in 0..<PlaylistLimits.maxMetadataAttempts {
            store.recordMetadataFailure(itemID: a.id, in: p.id)
        }
        store.markUnavailable(itemID: b.id, in: p.id)
        #expect(store.itemsNeedingMetadata(limit: 10).isEmpty)
    }

    // MARK: - Debounced save

    private final class CountingSerializer: PlaylistSerializing, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func encode(_ file: PlaylistFile) throws -> Data {
            lock.lock(); _count += 1; lock.unlock()
            return try JSONPlaylistSerializer().encode(file)
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    @Test("A debounced mutation lands on disk without a flush")
    func debouncedWriteLands() async throws {
        let d = try freshDir()
        let store = PlaylistStore(storage: PlaylistStorage(directory: d), saveDebounce: .milliseconds(50))
        _ = try store.createPlaylist(name: "Later")
        try await settle()
        let reloaded = PlaylistStore(storage: PlaylistStorage(directory: d))
        #expect(reloaded.playlists.contains { $0.name == "Later" })
    }

    @Test("Rapid mutations coalesce into a single write")
    func rapidMutationsCoalesce() async throws {
        let d = try freshDir()
        let counter = CountingSerializer()
        let store = PlaylistStore(storage: PlaylistStorage(directory: d, serializer: counter), saveDebounce: .milliseconds(50))
        for i in 1...5 { _ = try store.createPlaylist(name: "P\(i)") }
        try await settle()
        #expect(counter.count == 1)
        let reloaded = PlaylistStore(storage: PlaylistStorage(directory: d))
        #expect(reloaded.playlists.count == 6)
    }

    @Test("No debounced write fires in read-only mode")
    func readOnlyNoDebouncedWrite() async throws {
        let d = try freshDir()
        let url = d.appendingPathComponent("playlists.json")
        let json = #"{"schemaVersion":2,"playlists":[{"id":"\#(UUID().uuidString)","name":"Future","isFavorites":false,"items":[],"createdAt":0}]}"#
        try Data(json.utf8).write(to: url)
        let counter = CountingSerializer()
        let store = PlaylistStore(storage: PlaylistStorage(directory: d, serializer: counter), saveDebounce: .milliseconds(50))
        #expect(store.isReadOnly)
        _ = try store.createPlaylist(name: "X")
        try await settle()
        #expect(counter.count == 0)
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }
}
