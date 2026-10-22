import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var store: PlaylistStore
    @State private var showingNew = false
    @State private var newName = ""
    @State private var errorText: String?
    @State private var renamingID: UUID?
    @State private var renameText = ""

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
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if !p.isFavorites && canEdit {
                            Button("Rename") { renameText = p.name; renamingID = p.id }
                                .tint(.blue)
                        }
                    }
                }
                .onDelete { offsets in
                    guard canEdit else { return }
                    // Resolve to ids first: each deletion shifts later indices.
                    // deletePlaylist throws for Favorites, preserving the guard.
                    let ids = offsets.map { store.playlists[$0].id }
                    for id in ids { try? store.deletePlaylist(id: id) }
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
                // A blank name can't be submitted, so no second alert is needed
                // on the normal path (a second alert presented while the first
                // dismisses can be dropped by SwiftUI).
                Button("Create") {
                    do { _ = try store.createPlaylist(name: newName) }
                    catch { showError("Give the playlist a name.") }
                }
                .disabled(!PlaylistEditing.canSubmit(name: newName))
            }
            .alert("Rename playlist", isPresented: Binding(
                get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let id = renamingID else { return }
                    do { try store.renamePlaylist(id: id, to: renameText) }
                    catch PlaylistStore.StoreError.blankName { showError("Give the playlist a name.") }
                    catch { showError("That playlist can't be renamed.") }
                }
                .disabled(!PlaylistEditing.canSubmit(name: renameText))
            }
            .alert("Can't do that", isPresented: Binding(
                get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    /// Defer so the originating alert has finished dismissing.
    private func showError(_ text: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            errorText = text
        }
    }
}
