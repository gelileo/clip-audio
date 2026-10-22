import SwiftUI

struct PlaylistPickerView: View {
    let track: Track
    @EnvironmentObject private var store: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var showingNew = false
    @State private var note: String?

    private var canEdit: Bool { PlaylistEditing.canEdit(isReadOnly: store.isReadOnly) }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    newName = ""; showingNew = true
                } label: { Label("New playlist…", systemImage: "plus") }
                    .disabled(!canEdit)

                ForEach(store.playlists) { p in
                    Button {
                        let outcome = store.add(track: track, to: p.id)
                        if let msg = AddToPlaylistFeedback.message(for: outcome, playlistName: p.name) {
                            note = msg
                        } else {
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Image(systemName: p.isFavorites ? "heart.fill" : "music.note.list")
                                .foregroundStyle(p.isFavorites ? .pink : .secondary)
                            Text(p.name)
                            Spacer()
                            if p.contains(sourceURL: track.sourceURL) {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!canEdit)
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New playlist", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    if let p = try? store.createPlaylist(name: newName) {
                        _ = store.add(track: track, to: p.id)
                        dismiss()
                    } else {
                        note = "Couldn't create that playlist."
                    }
                }
                .disabled(!PlaylistEditing.canSubmit(name: newName))
            }
            .overlay(alignment: .bottom) {
                if let n = note {
                    Text(n).font(.caption).padding(8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .task(id: n) {
                            try? await Task.sleep(for: .seconds(2))
                            note = nil
                        }
                }
            }
        }
    }
}
