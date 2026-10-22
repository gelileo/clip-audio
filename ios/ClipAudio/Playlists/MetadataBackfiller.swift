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
    /// Identifies the current loop so a finishing old loop cannot clear the
    /// handle of a newer one.
    private var loopToken = UUID()
    /// Items being resolved right now, so overlapping `runOnce` calls never
    /// resolve (and count an attempt for) the same item twice.
    private var inFlight: Set<UUID> = []

    var isRunning: Bool { loop != nil }

    init(store: PlaylistStore, source: StreamSource) {
        self.store = store
        self.source = source
    }

    private enum Outcome {
        case resolved(Track)
        case failed(YtDlpStreamSource.ResolveError?)
        case cancelled
    }

    /// Resolve one batch. Separate from `start()` so tests can step it.
    /// Safe to call concurrently: in-flight items are skipped.
    func runOnce() async {
        let candidates = store.itemsNeedingMetadata(limit: Self.concurrency + inFlight.count)
        let batch = Array(candidates.filter { !inFlight.contains($0.item.id) }
            .prefix(Self.concurrency))
        guard !batch.isEmpty else { return }
        let ids = batch.map(\.item.id)
        inFlight.formUnion(ids)
        defer { inFlight.subtract(ids) }

        await withTaskGroup(of: (UUID, UUID, Outcome).self) { group in
            for (playlistID, item) in batch {
                group.addTask { [source] in
                    do {
                        return (playlistID, item.id, .resolved(try await source.resolve(item.sourceURL)))
                    } catch is CancellationError {
                        return (playlistID, item.id, .cancelled)
                    } catch {
                        if Task.isCancelled { return (playlistID, item.id, .cancelled) }
                        return (playlistID, item.id,
                                .failed(error as? YtDlpStreamSource.ResolveError))
                    }
                }
            }
            for await (playlistID, itemID, outcome) in group {
                switch outcome {
                case .cancelled:
                    // Backgrounding must not burn an attempt.
                    continue
                case let .resolved(t):
                    // Copy metadata only. The stream URL is deliberately dropped:
                    // PRD C8 forbids persisting it, and ResolvedMetadata has no
                    // field for it.
                    let m = ResolvedMetadata(title: t.title, uploader: t.uploader,
                                             duration: t.duration, artworkURL: t.artworkURL)
                    // Refused when there is no usable title: that is a failed
                    // attempt, so the item stays retryable up to the cap.
                    if !store.applyMetadata(m, toItemID: itemID, in: playlistID) {
                        store.recordMetadataFailure(itemID: itemID, in: playlistID)
                    }
                case let .failed(error):
                    if error?.isDefinitive == true {
                        store.markUnavailable(itemID: itemID, in: playlistID)
                    } else {
                        store.recordMetadataFailure(itemID: itemID, in: playlistID)
                    }
                }
            }
        }
    }

    /// Run batches until nothing is left. Foreground only — call `stop()`
    /// when the app backgrounds. Idempotent while a loop is running.
    func start() {
        guard loop == nil else { return }
        let token = UUID()
        loopToken = token
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.store.itemsNeedingMetadata(limit: 1).isEmpty { break }
                await self.runOnce()
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Only clear the handle if it is still ours.
            if let self, self.loopToken == token { self.loop = nil }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        loopToken = UUID()
    }
}
