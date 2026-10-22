import Combine
import Foundation

/// Owns the playlist library in memory and publishes it to SwiftUI.
/// All file IO is delegated to `PlaylistStorage`.
@MainActor
final class PlaylistStore: ObservableObject {
    enum StoreError: Error, Equatable {
        case blankName
        case favoritesImmutable
    }

    @Published private(set) var playlists: [Playlist] = []
    /// Set when something happened the user should know about (recovered a
    /// corrupt file, or the library was written by a newer build).
    @Published private(set) var statusMessage: String?
    @Published private(set) var isReadOnly = false

    static let shared = PlaylistStore()

    private let storage: PlaylistStorage
    private var saveTask: Task<Void, Never>?
    private let saveDebounce: Duration = .milliseconds(500)

    init(storage: PlaylistStorage) {
        self.storage = storage
        switch storage.load() {
        case let .loaded(file):
            playlists = file.playlists
        case let .seeded(file, recovered):
            playlists = file.playlists
            if let r = recovered {
                statusMessage = "Your playlist file couldn't be read and was kept as "
                    + "\(r.lastPathComponent). Starting fresh."
            }
        case let .readOnly(file):
            playlists = file.playlists
            isReadOnly = true
            statusMessage = "This library was written by a newer version of ClipAudio. "
                + "It's shown read-only so nothing is overwritten."
        case .unreadable:
            // Real user data we failed to read: never write over it.
            playlists = PlaylistStorage.seededFile().playlists
            isReadOnly = true
            statusMessage = "Your playlists couldn't be read, so changes won't be saved "
                + "this session. Your data on disk has not been touched."
        }
        ensureFavoritesPinned()
    }

    private convenience init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipAudio", isDirectory: true)
        self.init(storage: PlaylistStorage(directory: base))
    }

    var favorites: Playlist {
        playlists.first { $0.isFavorites } ?? Playlist(name: "Favorites", isFavorites: true)
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(name: String) throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.blankName }
        let p = Playlist(name: trimmed)
        playlists.append(p)
        scheduleSave()
        return p
    }

    func renamePlaylist(id: UUID, to name: String) throws {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[i].isFavorites else { throw StoreError.favoritesImmutable }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.blankName }
        playlists[i].name = trimmed
        scheduleSave()
    }

    func deletePlaylist(id: UUID) throws {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[i].isFavorites else { throw StoreError.favoritesImmutable }
        playlists.remove(at: i)
        scheduleSave()
    }

    /// Favorites is pinned, so a move is applied and then Favorites is
    /// re-asserted at index 0 regardless of where the drag landed.
    func movePlaylists(fromOffsets: IndexSet, toOffset: Int) {
        playlists.move(fromOffsets: fromOffsets, toOffset: toOffset)
        ensureFavoritesPinned()
        scheduleSave()
    }

    private func ensureFavoritesPinned() {
        if let i = playlists.firstIndex(where: { $0.isFavorites }), i != 0 {
            let f = playlists.remove(at: i)
            playlists.insert(f, at: 0)
        }
        if !playlists.contains(where: { $0.isFavorites }) {
            playlists.insert(Playlist(name: "Favorites", isFavorites: true), at: 0)
        }
    }

    // MARK: - Items

    @discardableResult
    func add(sourceURL: String, to playlistID: UUID) -> AddOutcome? {
        add(item: PlaylistItem(sourceURL: sourceURL), to: playlistID)
    }

    @discardableResult
    func add(track: Track, to playlistID: UUID) -> AddOutcome? {
        add(item: PlaylistItem(from: track), to: playlistID)
    }

    private func add(item: PlaylistItem, to playlistID: UUID) -> AddOutcome? {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return nil }
        if let existing = playlists[i].items.first(where: { $0.sourceURL == item.sourceURL }) {
            return .alreadyPresent(existing)
        }
        playlists[i].items.append(item)
        scheduleSave()
        return .added(item)
    }

    func remove(itemID: UUID, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].items.removeAll { $0.id == itemID }
        scheduleSave()
    }

    func moveItems(in playlistID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        scheduleSave()
    }

    // MARK: - Favorites shortcut

    func isFavorited(sourceURL: String) -> Bool {
        favorites.contains(sourceURL: sourceURL)
    }

    /// Returns the new state: true if now favorited.
    @discardableResult
    func toggleFavorite(sourceURL: String, metadataFrom track: Track?) -> Bool {
        guard let i = playlists.firstIndex(where: { $0.isFavorites }) else { return false }
        if let existing = playlists[i].items.first(where: { $0.sourceURL == sourceURL }) {
            playlists[i].items.removeAll { $0.id == existing.id }
            scheduleSave()
            return false
        }
        // Hearting what is already playing costs no extra network: the Track
        // carries the metadata, so the backfiller will skip this item.
        let item = track.map { PlaylistItem(from: $0) } ?? PlaylistItem(sourceURL: sourceURL)
        playlists[i].items.append(item)
        scheduleSave()
        return true
    }

    // MARK: - Metadata

    func applyMetadata(_ m: ResolvedMetadata, toItemID itemID: UUID, in playlistID: UUID) {
        guard let p = playlists.firstIndex(where: { $0.id == playlistID }),
              let i = playlists[p].items.firstIndex(where: { $0.id == itemID })
        else { return }   // user deleted it mid-flight; nothing to do
        playlists[p].items[i].apply(m)
        scheduleSave()
    }

    func recordMetadataFailure(itemID: UUID, in playlistID: UUID) {
        guard let p = playlists.firstIndex(where: { $0.id == playlistID }),
              let i = playlists[p].items.firstIndex(where: { $0.id == itemID })
        else { return }
        playlists[p].items[i].metadataAttempts += 1
        scheduleSave()
    }

    func resetMetadataAttempts(itemID: UUID, in playlistID: UUID) {
        guard let p = playlists.firstIndex(where: { $0.id == playlistID }),
              let i = playlists[p].items.firstIndex(where: { $0.id == itemID })
        else { return }
        playlists[p].items[i].metadataAttempts = 0
        scheduleSave()
    }

    func markUnavailable(itemID: UUID, in playlistID: UUID) {
        guard let p = playlists.firstIndex(where: { $0.id == playlistID }),
              let i = playlists[p].items.firstIndex(where: { $0.id == itemID })
        else { return }
        playlists[p].items[i].unavailable = true
        scheduleSave()
    }

    func itemsNeedingMetadata(limit: Int) -> [(playlistID: UUID, item: PlaylistItem)] {
        var out: [(UUID, PlaylistItem)] = []
        for p in playlists {
            for item in p.items
            where item.metadataFetchedAt == nil
                && !item.unavailable
                && item.metadataAttempts < PlaylistLimits.maxMetadataAttempts {
                out.append((p.id, item))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard !isReadOnly else { return }
        saveTask?.cancel()
        let snapshot = playlists
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: self?.saveDebounce ?? .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.write(snapshot)
        }
    }

    /// Bypass the debounce and write now. Call on app background.
    func flush() {
        saveTask?.cancel()
        guard !isReadOnly else { return }
        write(playlists)
    }

    private func write(_ snapshot: [Playlist]) {
        guard !isReadOnly else { return }
        do {
            try storage.save(PlaylistFile(
                schemaVersion: PlaylistFile.currentSchemaVersion, playlists: snapshot))
        } catch {
            statusMessage = "Couldn't save playlists: \(error.localizedDescription)"
        }
    }

    func dismissStatus() { statusMessage = nil }
}
