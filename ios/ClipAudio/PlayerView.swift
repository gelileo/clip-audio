import SwiftUI

struct PlayerView: View {
    @StateObject private var player = AudioPlayer.shared
    @State private var input = ""
    @State private var clipboardSuggestion: String?
    @State private var showHarness = false
    @State private var showingPicker = false
    @EnvironmentObject private var store: PlaylistStore
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                nowPlaying
                Divider()
                inputRow
                queueList
            }
            .navigationTitle("ClipAudio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHarness = true } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("Diagnostics")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingPicker = true } label: {
                        Image(systemName: "text.badge.plus")
                    }
                    .disabled(player.current == nil || store.isReadOnly)
                    .accessibilityLabel("Add to playlist")
                }
            }
            .sheet(isPresented: $showHarness) { M1HarnessView() }
            .sheet(isPresented: $showingPicker) {
                if let t = player.current { PlaylistPickerView(track: t) }
            }
            .task {
                checkClipboard()
                // Off by default. Enable in Diagnostics; it drives real
                // playback, so it would otherwise hijack every launch.
                if DebugSettings.selfTestOnLaunch {
                    await SelfTest.run(trigger: "launch")
                }
            }
        }
    }

    // MARK: - Now playing

    private var nowPlaying: some View {
        VStack(spacing: 12) {
            artwork
            VStack(spacing: 2) {
                HStack(spacing: 10) {
                    Text(player.current?.displayTitle ?? "Nothing playing")
                        .font(.headline).lineLimit(2).multilineTextAlignment(.center)
                    if let t = player.current {
                        // Read live from the store each render; never cached.
                        let fav = store.isFavorited(sourceURL: t.sourceURL)
                        Button {
                            _ = store.toggleFavorite(sourceURL: t.sourceURL, metadataFrom: t)
                        } label: {
                            Image(systemName: fav ? "heart.fill" : "heart")
                                .foregroundStyle(.pink)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isReadOnly)
                        .accessibilityLabel(AddToPlaylistFeedback.heartLabel(isFavorited: fav))
                    }
                }
                Text(player.current?.uploader ?? " ")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let ctx = player.playbackContext {
                    Text("Playing from \(ctx)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            scrubber
            transport
            HStack(spacing: 6) {
                if player.isBuffering { ProgressView().controlSize(.mini) }
                Text(player.statusLine).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(width: 180, height: 180)
            if let s = player.current?.artworkURL, let url = URL(string: s) {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
                }
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { player.position },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            HStack {
                Text(timeString(player.position))
                Spacer()
                Text(player.duration > 0 ? timeString(player.duration) : "--:--")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .disabled(player.duration <= 0)
    }

    private var transport: some View {
        HStack(spacing: 36) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .disabled(player.index + 1 >= player.queue.count)
        }
        .font(.title2)
    }

    // MARK: - Input

    private var inputRow: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("Paste a link", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(submit)
                Button("Play", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let s = clipboardSuggestion, s != input {
                Button {
                    input = s; submit()
                } label: {
                    Label("Play \(shorten(s))", systemImage: "doc.on.clipboard")
                        .font(.caption).lineLimit(1)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var queueList: some View {
        List {
            if player.queue.isEmpty {
                Text("Queue is empty").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, t in
                HStack {
                    Image(systemName: i == player.index ? "speaker.wave.2.fill" : "music.note")
                        .foregroundStyle(i == player.index ? Color.accentColor : .secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.displayTitle).lineLimit(1).font(.subheadline)
                        if let u = t.uploader {
                            Text(u).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    // Pre-resolved items show a tick: the next track is
                    // resolved while the current one plays (PRD C9).
                    if t.streamURL != nil && i != player.index {
                        Image(systemName: "checkmark.circle")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Helpers

    private func submit() {
        let url = input.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        inputFocused = false          // dismiss the keyboard
        player.enqueue(url)
        input = ""
        clipboardSuggestion = nil
    }

    private func checkClipboard() {
        guard UIPasteboard.general.hasURLs, let u = UIPasteboard.general.url else { return }
        clipboardSuggestion = u.absoluteString
    }

    private func shorten(_ s: String) -> String {
        s.count > 44 ? String(s.prefix(44)) + "…" : s
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "--:--" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
