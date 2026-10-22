import SwiftUI

struct PlaylistDetailView: View {
    let playlistID: UUID
    @EnvironmentObject private var store: PlaylistStore
    @StateObject private var player = AudioPlayer.shared

    private var playlist: Playlist? { store.playlists.first { $0.id == playlistID } }
    private var canEdit: Bool { PlaylistEditing.canEdit(isReadOnly: store.isReadOnly) }

    var body: some View {
        List {
            Button {
                if let p = playlist { player.play(playlist: p, startingAt: 0) }
            } label: {
                Label("Play all", systemImage: "play.fill")
            }
            .disabled(!PlaylistEditing.canPlayAll(playlist))

            ForEach(Array((playlist?.items ?? []).enumerated()), id: \.element.id) { i, item in
                row(item, index: i)
                    .deleteDisabled(!canEdit)
                    .moveDisabled(!canEdit)
            }
            .onDelete { offsets in
                guard canEdit, let p = playlist else { return }
                for i in offsets { store.remove(itemID: p.items[i].id, from: p.id) }
            }
            .onMove { from, to in
                guard canEdit else { return }
                store.moveItems(in: playlistID, fromOffsets: from, toOffset: to)
            }
            if playlist?.items.isEmpty ?? true {
                Text("Nothing here yet").foregroundStyle(.secondary).font(.caption)
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!canEdit) } }
    }

    private func row(_ item: PlaylistItem, index: Int) -> some View {
        let state = PlaylistRowState.state(for: item)
        return HStack {
            Button {
                if let p = playlist { player.play(playlist: p, startingAt: index) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle)
                        .lineLimit(1)
                        .foregroundStyle(item.unavailable ? .secondary : .primary)
                    detail(item, state: state)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if case .retryable = state {
                // Disabled when read-only: the reset would not persist.
                Button("Retry") {
                    store.retryMetadata(itemID: item.id, in: playlistID)
                }
                .font(.caption).buttonStyle(.borderless)
                .disabled(!canEdit)
            }
        }
    }

    @ViewBuilder
    private func detail(_ item: PlaylistItem, state: PlaylistRowState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .retryable(let unavailable):
                Text(unavailable ? "Unavailable" : "Couldn't load details")
                    .font(.caption2).foregroundStyle(.orange)
            case .loading:
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption2).foregroundStyle(.secondary)
            case .ready:
                if let u = item.uploader {
                    Text(u).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let d = item.duration {
                    Text(durationText(d)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func durationText(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s/3600, (s%3600)/60, s%60)
            : String(format: "%d:%02d", s/60, s%60)
    }
}
