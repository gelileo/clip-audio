import SwiftUI

/// M1 gate harness. Deliberately not the product UI — this exists to prove the
/// embedded interpreter boots and resolves, and to show the numbers the gate needs.
struct M1HarnessView: View {
    @State private var bootLine = "not booted"
    @State private var bootOK: Bool?
    @State private var url = "https://soundcloud.com/onda_andar/red-weather-prod-onda-andar"
    @State private var result = ""
    @State private var busy = false
    @State private var runHistory = "(loading…)"
    @State private var selfTestDone = false

    var body: some View {
        NavigationStack {
            Form {
                Section("1 · Interpreter") {
                    LabeledContent("Boot") {
                        HStack(spacing: 6) {
                            if let ok = bootOK {
                                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(ok ? .green : .red)
                            }
                            Text(bootLine).font(.caption.monospaced())
                        }
                    }
                    Button("Boot Python") { Task { await doBoot() } }.disabled(busy)
                }

                Section("2 · Resolve") {
                    TextField("URL", text: $url, axis: .vertical)
                        .font(.caption.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Resolve") { Task { await doResolve() } }
                        .disabled(busy || url.isEmpty)
                }

                Section("Self-test") {
                    Toggle("Run at launch", isOn: Binding(
                        get: { DebugSettings.selfTestOnLaunch },
                        set: { DebugSettings.selfTestOnLaunch = $0 }
                    ))
                    Text("Drives real playback and queues its own tracks. "
                         + "Cold-start numbers are only valid from a launch run.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Button {
                        Task {
                            busy = true
                            await SelfTest.run(trigger: "manual")
                            runHistory = SelfTest.history()
                            busy = false
                        }
                    } label: {
                        Label("Run now (warm)", systemImage: "play.circle")
                    }
                    .disabled(busy)
                }

                Section {
                    Text(runHistory)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Text("Detach Xcode, kill the app, relaunch from the home screen. "
                         + "Lines without [debugger] or [warm:…] are the real numbers.")
                        .font(.caption2).foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text("Run history")
                        Spacer()
                        if !selfTestDone {
                            Text("measuring…").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                if !result.isEmpty {
                    Section("Result") {
                        Text(result).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("ClipAudio M1")
            .overlay { if busy { ProgressView().controlSize(.large) } }
        }
        // The self-test runs from PlayerView (the root) so it sees a cold
        // interpreter. Running it here as well would double-measure and give
        // a warm, meaningless second reading.
        .task {
            runHistory = SelfTest.history()
            selfTestDone = true
            await doBoot()
        }
    }

    private func doBoot() async {
        busy = true; defer { busy = false }
        do {
            let (wall, p) = try await PythonRuntime.shared.boot()
            let ok = p["ok"] as? Bool ?? false
            bootOK = ok
            if ok {
                let imp = p["import_secs"] as? Double ?? -1
                bootLine = String(format: "%.2fs wall / %.2fs import · py %@ · yt-dlp %@",
                                  wall, imp,
                                  (p["python"] as? String) ?? "?",
                                  (p["ytdlp_version"] as? String) ?? "?")
            } else {
                bootLine = (p["error"] as? String) ?? "failed"
            }
        } catch {
            bootOK = false
            bootLine = error.localizedDescription
        }
    }

    private func doResolve() async {
        busy = true; defer { busy = false }
        do {
            var d = try await PythonRuntime.shared.resolve(url)
            let streamURL = (d["url"] as? String) ?? ""
            d["url"] = streamURL.isEmpty ? "" : "\(streamURL.prefix(60))… (\(streamURL.count) chars)"
            d["http_headers"] = (d["http_headers"] as? [String: Any])?.count ?? 0
            let pretty = try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
            result = String(data: pretty, encoding: .utf8) ?? ""
        } catch {
            result = "ERROR: \(error.localizedDescription)"
        }
    }
}
