import Testing
import Foundation
@testable import ClipAudio

@Suite("PlaylistStorage")
struct PlaylistStorageTests {

    /// Each test gets a throwaway directory so nothing touches the real library.
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("pltest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("A fresh directory seeds exactly one Favorites playlist")
    func seedsFavorites() throws {
        let s = PlaylistStorage(directory: try tempDir())
        guard case let .seeded(file, recovered) = s.load() else {
            Issue.record("expected .seeded"); return
        }
        #expect(recovered == nil)
        #expect(file.playlists.count == 1)
        #expect(file.playlists[0].isFavorites)
        #expect(file.playlists[0].name == "Favorites")
    }

    @Test("Saved content round-trips through load")
    func saveThenLoad() throws {
        let dir = try tempDir()
        let s = PlaylistStorage(directory: dir)
        var file = PlaylistStorage.seededFile()
        file.playlists.append(Playlist(name: "Focus",
                                       items: [PlaylistItem(sourceURL: "https://x/1")]))
        try s.save(file)

        guard case let .loaded(back) = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .loaded"); return
        }
        #expect(back.playlists.count == 2)
        #expect(back.playlists[1].name == "Focus")
        #expect(back.playlists[1].items[0].sourceURL == "https://x/1")
    }

    @Test("Malformed JSON is preserved and the store is re-seeded")
    func corruptFileRecovered() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("playlists.json")
        try Data("{ this is not json".utf8).write(to: url)

        guard case let .seeded(file, recovered) = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .seeded"); return
        }
        #expect(file.playlists.count == 1)
        let r = try #require(recovered)
        #expect(FileManager.default.fileExists(atPath: r.path))
        #expect(r.lastPathComponent.contains("corrupt"))
    }

    // Review Focus #2: a crash on an older build can leave a zero-byte file.
    // That is not malformed JSON and must not crash or silently yield nothing.
    @Test("A zero-byte store file recovers like corruption")
    func emptyFileRecovered() throws {
        let dir = try tempDir()
        try Data().write(to: dir.appendingPathComponent("playlists.json"))

        guard case let .seeded(file, recovered) = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .seeded"); return
        }
        #expect(file.playlists.count == 1)
        #expect(recovered != nil)
    }

    @Test("A file from a newer build loads read-only and refuses to save")
    func newerSchemaIsReadOnly() throws {
        let dir = try tempDir()
        let future = PlaylistFile(schemaVersion: 99,
                                  playlists: [Playlist(name: "From the future")])
        try Data(JSONEncoder().encode(future)).write(
            to: dir.appendingPathComponent("playlists.json"))

        let s = PlaylistStorage(directory: dir)
        guard case let .readOnly(file) = s.load() else {
            Issue.record("expected .readOnly"); return
        }
        #expect(file.playlists[0].name == "From the future")
        #expect(throws: PlaylistStorage.StorageError.self) {
            try s.save(file)
        }
    }

    @Test("A failed write leaves the previous file intact")
    func atomicWriteKeepsPriorState() throws {
        struct Exploding: PlaylistSerializing {
            func encode(_ file: PlaylistFile) throws -> Data {
                throw NSError(domain: "boom", code: 1)
            }
        }
        let dir = try tempDir()
        var good = PlaylistStorage.seededFile()
        good.playlists.append(Playlist(name: "Keep me"))
        try PlaylistStorage(directory: dir).save(good)

        #expect(throws: (any Error).self) {
            try PlaylistStorage(directory: dir, serializer: Exploding()).save(good)
        }

        guard case let .loaded(back) = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .loaded"); return
        }
        #expect(back.playlists.contains { $0.name == "Keep me" })
    }
}
