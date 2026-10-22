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
        /// IO error, quarantine failure, or an undecodable newer file. The file is
        /// untouched and the caller MUST NOT write.
        case unreadable(Error)
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
        // Missing is normal on first launch.
        guard fm.fileExists(atPath: fileURL.path) else {
            return .seeded(Self.seededFile(), recoveredFrom: nil)
        }
        // An IO error is NOT corruption: leave the file alone and tell the
        // caller not to write, or the next save would overwrite a healthy library.
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { return .unreadable(error) }

        // Zero bytes means a previous write died; preserve it like corruption.
        if data.isEmpty { return recover() }

        // Probe the version first so a newer build's file with a changed shape
        // is never mistaken for corruption.
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           probe.schemaVersion > PlaylistFile.currentSchemaVersion {
            do {
                return .readOnly(try JSONDecoder().decode(PlaylistFile.self, from: data))
            } catch {
                // Newer and undecodable by us: untouched on disk, not writable.
                return .unreadable(error)
            }
        }
        guard let file = try? JSONDecoder().decode(PlaylistFile.self, from: data) else {
            return recover()
        }
        return .loaded(migrate(file))
    }

    func save(_ file: PlaylistFile) throws {
        guard file.schemaVersion <= PlaylistFile.currentSchemaVersion else {
            throw StorageError.readOnlyNewerSchema(
                found: file.schemaVersion, supported: PlaylistFile.currentSchemaVersion)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // Encode before touching the destination, then one atomic write
        // (Foundation writes a temp file and renames it into place).
        var out = file
        out.schemaVersion = PlaylistFile.currentSchemaVersion
        let data = try serializer.encode(out)
        try data.write(to: fileURL, options: .atomic)
    }

    /// v1 is the initial version, so this is the identity case today. It
    /// exists so a future v2 has an obvious home.
    private func migrate(_ file: PlaylistFile) -> PlaylistFile {
        switch file.schemaVersion {
        case PlaylistFile.currentSchemaVersion: return file
        default: return file
        }
    }

    /// Quarantine the bad file and re-seed. If it cannot be preserved, hand back
    /// `.unreadable` so no writable store is ever returned over unsaved data.
    private func recover() -> LoadResult {
        do {
            let moved = try quarantine()
            return .seeded(Self.seededFile(), recoveredFrom: moved)
        } catch {
            return .unreadable(error)
        }
    }

    private struct VersionProbe: Decodable { let schemaVersion: Int }

    /// Move an unreadable file aside. Never delete it — it is the user's data.
    private func quarantine() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        let dest = directory.appendingPathComponent("playlists.corrupt-\(stamp)-\(suffix).json")
        try fm.moveItem(at: fileURL, to: dest)
        return dest
    }
}
