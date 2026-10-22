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

    @Test("A failed write leaves the previous file byte-identical")
    func atomicWriteKeepsPriorState() throws {
        let dir = try tempDir()
        var good = PlaylistStorage.seededFile()
        good.playlists.append(Playlist(name: "Keep me"))
        let s = PlaylistStorage(directory: dir)
        try s.save(good)
        let url = dir.appendingPathComponent("playlists.json")
        let before = try Data(contentsOf: url)

        // Fails at write time (no temp file can be created), after encoding.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        var changed = good
        changed.playlists.append(Playlist(name: "Never lands"))
        #expect(throws: (any Error).self) { try s.save(changed) }

        #expect(try Data(contentsOf: url) == before)
    }

    @Test("A transient read error is unreadable and leaves the file in place")
    func readErrorIsNotCorruption() throws {
        let dir = try tempDir()
        var good = PlaylistStorage.seededFile()
        good.playlists.append(Playlist(name: "Healthy"))
        try PlaylistStorage(directory: dir).save(good)
        let url = dir.appendingPathComponent("playlists.json")
        let before = try Data(contentsOf: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard case .unreadable = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .unreadable"); return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.contains { $0.contains("corrupt") })
    }

    @Test("A failed quarantine is unreadable, never a writable seed")
    func quarantineFailureIsUnreadable() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("playlists.json")
        let bad = Data("{ nope".utf8)
        try bad.write(to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard case .unreadable = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .unreadable"); return
        }
        #expect(try Data(contentsOf: url) == bad)
    }

    @Test("Recovery preserves the bad bytes and clears playlists.json")
    func quarantinePreservesBytes() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("playlists.json")
        let bad = Data("{ this is not json".utf8)
        try bad.write(to: url)

        guard case let .seeded(_, recovered) = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .seeded"); return
        }
        let r = try #require(recovered)
        #expect(try Data(contentsOf: r) == bad)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Two corruptions in the same second do not collide")
    func quarantineNamesUnique() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("playlists.json")
        var seen = Set<URL>()
        for i in 0..<3 {
            try Data("bad\(i)".utf8).write(to: url)
            guard case let .seeded(_, r) = PlaylistStorage(directory: dir).load() else {
                Issue.record("expected .seeded"); return
            }
            seen.insert(try #require(r))
        }
        #expect(seen.count == 3)
    }

    @Test("A newer file with a changed shape is read-only or unreadable, never quarantined")
    func newerUnknownShapeNotQuarantined() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("playlists.json")
        let future = Data(#"{"schemaVersion": 99, "playlists": "now a string"}"#.utf8)
        try future.write(to: url)

        if case .loaded = PlaylistStorage(directory: dir).load() { Issue.record("must not be .loaded") }
        if case .seeded = PlaylistStorage(directory: dir).load() { Issue.record("must not be .seeded") }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test("Read-only load leaves the file untouched on disk")
    func readOnlyLeavesFileUntouched() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("playlists.json")
        let future = PlaylistFile(schemaVersion: 99, playlists: [Playlist(name: "F")])
        try JSONEncoder().encode(future).write(to: url)
        let before = try Data(contentsOf: url)

        guard case .readOnly = PlaylistStorage(directory: dir).load() else {
            Issue.record("expected .readOnly"); return
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["playlists.json"])
    }
}
