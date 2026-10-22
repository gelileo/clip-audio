import Foundation

enum PlaylistLimits {
    /// Metadata backfill stops after this many failed attempts on one item.
    static let maxMetadataAttempts = 3
}

/// A saved reference to something playable.
///
/// Storage type, deliberately distinct from `Track` (playback). It has no
/// field for a resolved stream URL: PRD C8 says those expire and are client-
/// bound, so the type system — not discipline — keeps them out of the library.
struct PlaylistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceURL: String
    var title: String?
    var uploader: String?
    var duration: Double?
    var artworkURL: String?
    var addedAt: Date
    var metadataFetchedAt: Date?
    var metadataAttempts: Int
    var unavailable: Bool

    init(id: UUID = UUID(),
         sourceURL: String,
         title: String? = nil,
         uploader: String? = nil,
         duration: Double? = nil,
         artworkURL: String? = nil,
         addedAt: Date = Date(),
         metadataFetchedAt: Date? = nil,
         metadataAttempts: Int = 0,
         unavailable: Bool = false) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.uploader = uploader
        self.duration = duration
        self.artworkURL = artworkURL
        self.addedAt = addedAt
        self.metadataFetchedAt = metadataFetchedAt
        self.metadataAttempts = metadataAttempts
        self.unavailable = unavailable
    }

    var hasMetadata: Bool { metadataFetchedAt != nil }
    var displayTitle: String { title ?? sourceURL }
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isFavorites: Bool
    var items: [PlaylistItem]
    var createdAt: Date

    init(id: UUID = UUID(),
         name: String,
         isFavorites: Bool = false,
         items: [PlaylistItem] = [],
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isFavorites = isFavorites
        self.items = items
        self.createdAt = createdAt
    }

    func contains(sourceURL: String) -> Bool {
        items.contains { $0.sourceURL == sourceURL }
    }
}

struct PlaylistFile: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var playlists: [Playlist]
}

enum AddOutcome: Equatable {
    case added(PlaylistItem)
    case alreadyPresent(PlaylistItem)
}

/// Metadata only. Exists so backfill cannot carry a stream URL into storage.
struct ResolvedMetadata: Equatable {
    let title: String?
    let uploader: String?
    let duration: Double?
    let artworkURL: String?

    /// True when the resolve produced nothing worth showing.
    var isEmpty: Bool {
        title == nil && uploader == nil && duration == nil && artworkURL == nil
    }
}

extension PlaylistItem {
    /// Snapshot a playback Track for storage. Drops streamURL/formatID/resolvedAt.
    init(from track: Track) {
        self.init(sourceURL: track.sourceURL,
                  title: track.title,
                  uploader: track.uploader,
                  duration: track.duration,
                  artworkURL: track.artworkURL,
                  metadataFetchedAt: track.title == nil ? nil : Date())
    }

    mutating func apply(_ m: ResolvedMetadata) {
        title = m.title ?? title
        uploader = m.uploader ?? uploader
        duration = m.duration ?? duration
        artworkURL = m.artworkURL ?? artworkURL
        metadataFetchedAt = Date()
    }
}

extension Track {
    /// Build a playable Track from a stored item. Unresolved by construction.
    init(from item: PlaylistItem) {
        self.init(sourceURL: item.sourceURL)
        self.title = item.title
        self.uploader = item.uploader
        self.duration = item.duration
        self.artworkURL = item.artworkURL
    }
}
