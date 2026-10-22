import Combine
import SwiftUI

struct RootTabView: View {
    @StateObject private var store = PlaylistStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var backfiller: MetadataBackfiller?

    var body: some View {
        TabView {
            PlayerView()
                .tabItem { Label("Now Playing", systemImage: "play.circle") }
            PlaylistsView()
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
        }
        .environmentObject(store)
        .task {
            guard backfiller == nil else { return }
            let bf = MetadataBackfiller(store: store, source: YtDlpStreamSource())
            backfiller = bf
            startBackfillerIfWritable()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                startBackfillerIfWritable()
            case .background, .inactive:
                // Backgrounded WKWebView/network work is throttled, and a
                // debounced save could be lost if we are suspended (PRD C9).
                backfiller?.stop()
                store.flush()
            @unknown default:
                break
            }
        }
        .onReceive(AudioPlayer.shared.deadSourceURL) { url in
            // Every stored copy of the link is marked; rows in different
            // playlists are independent.
            store.markUnavailable(sourceURL: url)
        }
        .alert("Playlists",
               isPresented: Binding(get: { store.statusMessage != nil },
                                    set: { if !$0 { store.dismissStatus() } })) {
            Button("OK") { store.dismissStatus() }
        } message: {
            Text(store.statusMessage ?? "")
        }
    }

    /// A library we cannot save should not be churned against (network,
    /// WKWebView, attempt counters, in-memory-only unavailable marks).
    private func startBackfillerIfWritable() {
        guard !store.isReadOnly else { return }
        backfiller?.start()
    }
}
