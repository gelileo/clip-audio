import Foundation

/// What a playlist item row should show. Pure so the retry rules are testable.
enum PlaylistRowState: Equatable {
    case ready
    case loading
    /// Metadata is not coming on its own; the person can ask for another go.
    case retryable(unavailable: Bool)

    static func state(for item: PlaylistItem,
                      maxAttempts: Int = MetadataBackfiller.maxMetadataAttempts) -> PlaylistRowState {
        // `unavailable` items are filtered out of the backfill queue, so a
        // false positive is only recoverable through this affordance.
        if item.unavailable { return .retryable(unavailable: true) }
        if item.hasMetadata { return .ready }
        if item.metadataAttempts >= maxAttempts { return .retryable(unavailable: false) }
        return .loading
    }
}

enum PlaylistEditing {
    static func canEdit(isReadOnly: Bool) -> Bool { !isReadOnly }
    static func canPlayAll(_ playlist: Playlist?) -> Bool { !(playlist?.items.isEmpty ?? true) }
}
