import SwiftUI

struct RootTabView: View {
    @StateObject private var store = PlaylistStore.shared

    var body: some View {
        TabView {
            PlayerView()
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
        }
        .environmentObject(store)
        .alert("Playlists",
               isPresented: Binding(get: { store.statusMessage != nil },
                                    set: { if !$0 { store.dismissStatus() } })) {
            Button("OK") { store.dismissStatus() }
        } message: {
            Text(store.statusMessage ?? "")
        }
    }
}
