import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var showingNew = false
    @State private var newName = ""
    @State private var errorText: String?

    private var canEdit: Bool { PlaylistEditing.canEdit(isReadOnly: store.isReadOnly) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.playlists) { p in
                    NavigationLink(value: p.id) {
                        HStack {
                            Image(systemName: p.isFavorites ? "heart.fill" : "music.note.list")
                                .foregroundStyle(p.isFavorites ? .pink : .secondary)
                                .frame(width: 22)
                            Text(p.name)
                            Spacer()
                            Text("\(p.items.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .deleteDisabled(p.isFavorites || !canEdit)
                    .moveDisabled(p.isFavorites || !canEdit)
                }
                .onDelete { offsets in
                    guard canEdit else { return }
                    for i in offsets where !store.playlists[i].isFavorites {
                        try? store.deletePlaylist(id: store.playlists[i].id)
                    }
                }
                .onMove { from, to in
                    guard canEdit else { return }
                    store.movePlaylists(fromOffsets: from, toOffset: to)
                }
            }
            .navigationTitle("Playlists")
            .navigationDestination(for: UUID.self) { id in
                PlaylistDetailView(playlistID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; showingNew = true } label: { Image(systemName: "plus") }
                        .disabled(!canEdit)
                        .accessibilityLabel("New playlist")
                }
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().disabled(!canEdit)
                }
            }
            .alert("New playlist", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    do { _ = try store.createPlaylist(name: newName) }
                    catch { errorText = "Give the playlist a name." }
                }
            }
            .alert("Can't do that", isPresented: Binding(
                get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }
}
