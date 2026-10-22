# ClipAudio — Playlists & Favorites

**Date:** 2026-10-22 · **Status:** approved for implementation
**Related:** `../../../prd.md` (US-04, US-05, C8, C9, §10)

## Intent

Curated, library-shaped collections. The user builds named playlists deliberately
and replays them; items persist indefinitely, manual order is meaningful, nothing
ages out automatically. Favorites is the one playlist that always exists, reached
in a single tap from the heart button.

Agreed in design discussion:

1. **Library-shaped, not inbox-shaped.** Replay is the primary action. Adding an
   item means choosing a playlist (or tapping the heart). Nothing auto-removes.
2. **A playlist replaces the queue.** Tapping a playlist loads it as the queue and
   starts playing; the previous queue is discarded. The queue stays transient and
   in-memory — it is not persisted.
3. **Favorites is an ordinary playlist, pre-created**, flagged undeletable and
   unrenameable. One model, one set of screens. The heart is a shortcut for
   "add to this particular playlist".

Not goals: cross-device sync, nested or smart playlists, offline downloads
(PRD N4), a persistent Up Next.

## Success criteria

- Create, rename, delete, and reorder playlists; Favorites resists delete and rename
- Add and remove items; manual reorder within a playlist
- Heart toggles the currently playing track in Favorites, reflecting state correctly
- A playlist survives relaunch, including order
- Tapping a playlist plays it; next/prev walk that playlist
- Adding is instant; metadata appears without blocking the add
- A corrupt or unreadable store never silently loses data
- Store logic is unit-tested without a simulator

## Data model

```swift
struct PlaylistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceURL: String            // durable identity; see C8 below
    var title: String?
    var uploader: String?
    var duration: Double?
    var artworkURL: String?
    var addedAt: Date
    var metadataFetchedAt: Date?     // nil = never successfully resolved
    var metadataAttempts: Int        // backfill stops at maxMetadataAttempts (3)
    var unavailable: Bool            // link resolved but is dead/blocked
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var isFavorites: Bool
    var items: [PlaylistItem]
    var createdAt: Date
}

struct PlaylistFile: Codable {
    var schemaVersion: Int           // current: 1
    var playlists: [Playlist]
}
```

**`PlaylistItem` deliberately has no stream-URL field.** PRD C8 states resolved
URLs expire (~6h) and are client-bound, so they are never persisted. Keeping
storage and playback as separate types makes that a property of the type system
rather than of discipline: there is nowhere to put a stream URL even by mistake.

`Track` (existing, playback) and `PlaylistItem` (storage) convert explicitly:

```swift
extension Track { init(from item: PlaylistItem) }      // metadata only
extension PlaylistItem { init(from track: Track) }     // drops streamURL/formatID/resolvedAt
```

Ordering is array order. No index field, no sort key.

## Storage

`PlaylistStore: ObservableObject`, `@MainActor`, owning `@Published private(set) var playlists: [Playlist]`.

Persisted to `Application Support/ClipAudio/playlists.json`.

| Concern | Decision |
|---|---|
| Write safety | Atomic: serialise to a temp file in the same directory, then `replaceItemAt`. A crash mid-write cannot corrupt the library. |
| Write frequency | Debounced ~0.5s and coalesced. A drag-reorder must not produce one write per frame. |
| Corrupt file | Rename to `playlists.corrupt-<ISO8601>.json`, start with a freshly seeded store, surface a user-visible message. **Never delete the unreadable file.** |
| Newer schema | If `schemaVersion` exceeds the build's, load read-only and refuse to write, surfacing a message. Do not clobber data written by a newer build. |
| Migration | A `switch` on `schemaVersion`. v1 is the initial version, so the only arm today is the identity case; the switch exists so a v2 has an obvious home. No framework. |
| First launch | Seed a single playlist, `isFavorites: true`, named "Favorites". |

Supporting types:

```swift
enum AddOutcome { case added(PlaylistItem), alreadyPresent(PlaylistItem) }

/// Metadata only. Exists so backfill cannot carry a stream URL into storage.
struct ResolvedMetadata {
    let title: String?
    let uploader: String?
    let duration: Double?
    let artworkURL: String?
}
```

Public surface (the whole API the UI may use):

```swift
func createPlaylist(name: String) -> Playlist
func renamePlaylist(id: UUID, to: String) throws      // throws for Favorites
func deletePlaylist(id: UUID) throws                  // throws for Favorites
func movePlaylists(fromOffsets: IndexSet, toOffset: Int)   // user playlists only; Favorites is pinned

func add(sourceURL: String, to playlistID: UUID) -> AddOutcome   // .added | .alreadyPresent
func add(track: Track, to playlistID: UUID) -> AddOutcome
func remove(itemID: UUID, from playlistID: UUID)
func moveItems(in playlistID: UUID, fromOffsets: IndexSet, toOffset: Int)

var favorites: Playlist { get }
func isFavorited(sourceURL: String) -> Bool
func toggleFavorite(sourceURL: String, metadataFrom: Track?) -> Bool   // returns new state
// When metadataFrom is non-nil (hearting the current track) the item is stored
// with metadata already populated and metadataFetchedAt set, so the backfiller
// skips it. Hearting what you are listening to costs no extra network.

func applyMetadata(_ m: ResolvedMetadata, toItemID: UUID, in playlistID: UUID)
func markUnavailable(itemID: UUID, in playlistID: UUID)
```

Deduplication is **by `sourceURL`, within a playlist**. Adding something already
present is a no-op returning `.alreadyPresent`, so the UI can say so rather than
silently creating a duplicate.

The same URL may appear in several playlists, and **those rows are independent**:
each has its own `id`, `addedAt`, and metadata state. Marking one `unavailable`
does not touch the others. This is deliberate — reconciling copies would need a
second identity concept, and the duplication costs nothing at this scale.

## Player integration

`AudioPlayer` gains:

```swift
func play(playlist: Playlist, startingAt index: Int)
var playbackContext: String?      // e.g. "Focus"; nil for ad-hoc links
```

`play(playlist:startingAt:)` maps items to Tracks, replaces the queue, and starts
at the given index. **Items whose metadata has not yet backfilled are still
playable** — playback resolves from `sourceURL` regardless, and metadata is only
a display concern. Existing `enqueue(_:)` is unchanged and continues to serve
pasted links.

**`AudioPlayer` must not reference `PlaylistStore`.** The dependency runs one way:
views own both and mediate. This keeps the player testable in isolation and keeps
playback free of storage concerns.

Existing behaviour that carries over unchanged: next-item pre-resolution (C9),
stale-resolution refresh after 3h (C8), and the failure ladder in PRD §10.

## Metadata backfill

Adding is instant. A new `PlaylistItem` carries only `sourceURL` and `addedAt`;
the row renders a shortened URL until metadata arrives.

`MetadataBackfiller`:

- Selects items where `metadataFetchedAt == nil && !unavailable && metadataAttempts < maxMetadataAttempts` (`maxMetadataAttempts = 3`, one constant on the backfiller)
- Resolves through the existing `StreamSource`, **copying metadata fields only** and
  discarding the stream URL
- Concurrency limit of 2; foreground only; cancelled on background
- On failure, increments `metadataAttempts`. At 3 it stops and the UI offers a retry
  that resets the counter.
- On a resolve that reports the item is gone, sets `unavailable`

Rationale for instant-add: blocking on a ~2s resolve makes the heart feel broken on
a slow connection, while never resolving leaves a library of untitled URLs. Neither
extreme is acceptable alone.

## UI

A `TabView` with two tabs: **Now Playing** and **Playlists**. Playlists are the
primary surface for a library-shaped feature and should not be behind a sheet.
Diagnostics stays in the Now Playing toolbar.

**Now Playing** — unchanged, plus:
- A heart button beside the title. Filled when the current track's `sourceURL` is in
  Favorites. Tapping toggles; un-hearting removes.
- An "Add to playlist" menu action opening the picker.
- When `playbackContext != nil`, a "Playing from <name>" line.

**Playlists tab** — list of playlists with item counts. **Favorites is pinned to the
top** with a heart glyph and is not draggable; the user playlists below it reorder
freely. `movePlaylists` therefore operates on the user-playlist subsequence and the
store re-asserts Favorites at index 0 after any move. Create via a toolbar "+".
Swipe to delete (disabled for Favorites).

**Playlist detail** — items with title, uploader and duration; tap to play from that
index; swipe to remove; drag to reorder; a "Play" action for the whole list. Items
awaiting metadata show the shortened URL with a subtle progress indicator; items at
`metadataAttempts == 3` show a retry button; `unavailable` items are dimmed with a
label.

**Picker sheet** — lists playlists with "New playlist…" at the top; reports
`.alreadyPresent` inline.

**Known gap, accepted for v1:** switching to the Playlists tab hides the now-playing
view. The conventional fix is a persistent mini-player above the tab bar; it is out
of scope here and recorded as follow-up.

## Failure handling

| Situation | Behaviour |
|---|---|
| Corrupt store file | Preserve as `.corrupt-<date>.json`, seed fresh, tell the user |
| Store written by a newer build | Load read-only, refuse writes, tell the user |
| Disk write fails | Surface the error; keep in-memory state; retry on next change |
| Add a URL already in that playlist | No-op, report `.alreadyPresent` |
| Playback resolve fails for an item | Existing PRD §10 ladder; mark `unavailable` on a definitive failure |
| Metadata backfill fails | Increment attempts; stop at 3; offer retry |
| Rename/delete attempted on Favorites | Throws; UI disables the affordance in the first place |

## Testing

This is the first component in the project that is unit-testable without a device.
A new `ClipAudioTests` target covers:

- Codable round-trip; unknown fields tolerated
- `schemaVersion` handling: current, older (migrates), newer (read-only)
- Corrupt-file recovery preserves the original and seeds fresh
- Atomic write: the destination is either the previous valid file or the complete new one — asserted by injecting a serializer that throws midway and confirming the on-disk file still parses as the prior state
- Favorites: seeded once, survives reload, rejects rename and delete
- Dedupe within a playlist; same URL allowed across playlists
- Reorder of playlists and of items, persisted across reload
- `toggleFavorite` round-trips and reports correct state
- Backfill against a stub `StreamSource`: success applies metadata, failure
  increments attempts, three failures stop retrying, stream URL is never stored

The last assertion matters disproportionately: it is the automated guard on PRD C8.

## Out of scope

Mini-player, share-extension integration (PRD US-01), export/import, sync,
smart playlists, per-playlist shuffle or repeat, playback position memory.
