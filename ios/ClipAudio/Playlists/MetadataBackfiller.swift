import Foundation

/// Fills in titles, artwork and durations for items added without them.
///
/// Adding must be instant — blocking a heart-tap on a ~2s network resolve
/// makes it feel broken — but a library of untitled URLs is useless. So the
/// add is cheap and this runs behind it.
@MainActor
final class MetadataBackfiller {
    static let maxMetadataAttempts = PlaylistLimits.maxMetadataAttempts
    private static let concurrency = 2

    private let store: PlaylistStore
    private let source: StreamSource
    private var loop: Task<Void, Never>?

    init(store: PlaylistStore, source: StreamSource) {
        self.store = store
        self.source = source
    }

    /// Resolve one batch. Separate from `start()` so tests can step it.
    func runOnce() async {
        let batch = store.itemsNeedingMetadata(limit: Self.concurrency)
        guard !batch.isEmpty else { return }

        await withTaskGroup(of: (UUID, UUID, Track?).self) { group in
            for (playlistID, item) in batch {
                group.addTask { [source] in
                    let track = try? await source.resolve(item.sourceURL)
                    return (playlistID, item.id, track)
                }
            }
            for await (playlistID, itemID, track) in group {
                // Copy metadata only. The stream URL is deliberately dropped:
                // PRD C8 forbids persisting it, and ResolvedMetadata has no
                // field for it.
                let metadata = track.map {
                    ResolvedMetadata(title: $0.title, uploader: $0.uploader,
                                     duration: $0.duration, artworkURL: $0.artworkURL)
                }
                if let m = metadata, !m.isEmpty {
                    store.applyMetadata(m, toItemID: itemID, in: playlistID)
                } else {
                    // Resolve failed, or "succeeded" with nothing to show. Either
                    // way the item must stay retryable (up to the limit) rather
                    // than be marked fetched while still titled by its raw URL.
                    store.recordMetadataFailure(itemID: itemID, in: playlistID)
                }
            }
        }
    }

    /// Run batches until nothing is left. Foreground only — call `stop()`
    /// when the app backgrounds.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.store.itemsNeedingMetadata(limit: 1).isEmpty { break }
                await self.runOnce()
                try? await Task.sleep(for: .milliseconds(250))
            }
            self?.loop = nil
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }
}
