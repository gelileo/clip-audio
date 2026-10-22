import Foundation

protocol PlaylistSerializing: Sendable {
    func encode(_ file: PlaylistFile) throws -> Data
}

struct JSONPlaylistSerializer: PlaylistSerializing {
    func encode(_ file: PlaylistFile) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(file)
    }
}

/// All file IO for the playlist library. Deliberately not `@MainActor` and
/// free of SwiftUI, so the whole of it is unit-testable with no simulator.
struct PlaylistStorage {
    enum StorageError: Error, Equatable {
        case readOnlyNewerSchema(found: Int, supported: Int)
    }

    enum LoadResult {
        case loaded(PlaylistFile)
        /// Nothing usable on disk. `recoveredFrom` names the preserved bad file, if any.
        case seeded(PlaylistFile, recoveredFrom: URL?)
        /// Written by a newer build: usable, but we must not write over it.
        case readOnly(PlaylistFile)
    }

    let directory: URL
    private let serializer: PlaylistSerializing
    private let fm = FileManager.default

    init(directory: URL, serializer: PlaylistSerializing = JSONPlaylistSerializer()) {
        self.directory = directory
        self.serializer = serializer
    }

    var fileURL: URL { directory.appendingPathComponent("playlists.json") }

    static func seededFile() -> PlaylistFile {
        PlaylistFile(schemaVersion: PlaylistFile.currentSchemaVersion,
                     playlists: [Playlist(name: "Favorites", isFavorites: true)])
    }

    func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            // Missing is normal on first launch. Empty is not — a zero-byte
            // file means a previous write died, so preserve it like corruption.
            let recovered = fm.fileExists(atPath: fileURL.path) ? quarantine() : nil
            return .seeded(Self.seededFile(), recoveredFrom: recovered)
        }
        guard let file = try? JSONDecoder().decode(PlaylistFile.self, from: data) else {
            return .seeded(Self.seededFile(), recoveredFrom: quarantine())
        }
        if file.schemaVersion > PlaylistFile.currentSchemaVersion {
            return .readOnly(file)
        }
        return .loaded(migrate(file))
    }

    func save(_ file: PlaylistFile) throws {
        guard file.schemaVersion <= PlaylistFile.currentSchemaVersion else {
            throw StorageError.readOnlyNewerSchema(
                found: file.schemaVersion, supported: PlaylistFile.currentSchemaVersion)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Encode before touching the destination: a serializer failure must
        // leave the existing library exactly as it was.
        var out = file
        out.schemaVersion = PlaylistFile.currentSchemaVersion
        let data = try serializer.encode(out)

        let tmp = directory.appendingPathComponent("playlists.\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: fileURL.path) {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: fileURL)
        }
    }

    /// v1 is the initial version, so this is the identity case today. It
    /// exists so a future v2 has an obvious home.
    private func migrate(_ file: PlaylistFile) -> PlaylistFile {
        switch file.schemaVersion {
        case PlaylistFile.currentSchemaVersion: return file
        default: return file
        }
    }

    /// Move an unreadable file aside. Never delete it — it is the user's data.
    private func quarantine() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = directory.appendingPathComponent("playlists.corrupt-\(stamp).json")
        do { try fm.moveItem(at: fileURL, to: dest); return dest } catch { return nil }
    }
}
