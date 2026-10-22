import Foundation

/// Machine-readable gate check. Prints `M1GATE:` lines so the milestone can be
/// verified from the command line instead of by reading a screen.
/// Runs on every launch; also reusable on-device.
enum SelfTest {
    /// Two checks with different jobs. `stack` proves the HTTP + extractor
    /// machinery is alive using whatever format a permissive source offers;
    /// `aac` proves the production selector works. A single flaky site must
    /// not be able to decide a milestone gate, so the gate passes if the
    /// stack check passes and at least one source resolves.
    struct Probe { let name: String; let url: String; let format: String? }
    static let probes = [
        // Deliberately a DIFFERENT host from the aac probe: one flaky site
        // must not be able to decide a gate. Generic extractor, direct media.
        Probe(name: "stack", url: "https://download.samplelib.com/mp3/sample-3s.mp3", format: "bestaudio/best"),
        Probe(name: "aac", url: "https://soundcloud.com/onda_andar/red-weather-prod-onda-andar", format: nil),
        // The actual use case. Uses yt-dlp's default client selection, which
        // currently picks visionos and needs no JS challenge at all — so this
        // is deliberately NOT the same thing the m2 benchmark measures.
        Probe(name: "youtube", url: "https://www.youtube.com/watch?v=iG9CE55wbtY", format: nil),
    ]

    /// One compact line per launch, accumulated across runs. Lets a build be
    /// measured with Xcode detached (no debugger inflating dyld) by reading
    /// the numbers on screen instead of in a console.
    /// Real P_TRACED check. Xcode attaches lldb, which is notified on every
    /// dylib load — with 31 extension frameworks that inflates exactly the
    /// cost under investigation, so each run must say whether it was traced.
    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = mib.withUnsafeMutableBufferPointer { p -> Int32 in
            sysctl(p.baseAddress, UInt32(p.count), &info, &size, nil, 0)
        }
        return rc == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Device vs simulator, plus hardware model. Without this a 0.3s reading
    /// is ambiguous between an A16 and the Mac running the simulator.
    static func hostTag() -> String {
        #if targetEnvironment(simulator)
        let kind = "SIM"
        #else
        let kind = "DEV"
        #endif
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return "\(kind):\(simModel ?? model)"
    }

    static func historyPath() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("history.txt")
    }

    static func history() -> String {
        guard let u = historyPath(), let s = try? String(contentsOf: u, encoding: .utf8)
        else { return "(no runs yet)" }
        return s
    }

    private static func appendHistory(_ line: String) {
        guard let u = historyPath() else { return }
        let prior = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        try? (prior + line + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    private static func parse(_ lines: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: lines.compactMap { l -> (String, String)? in
            let body = l.replacingOccurrences(of: "M1GATE: ", with: "")
            guard let eq = body.firstIndex(of: "=") else { return nil }
            return (String(body[body.startIndex..<eq]), String(body[body.index(after: eq)...]))
        })
    }

    /// `trigger` distinguishes a launch run (cold, valid for startup gates)
    /// from an on-demand run (warm — the interpreter is already up and the
    /// import cost is a replay of the first measurement, not a fresh one).
    static func run(trigger: String = "launch") async {
        var lines: [String] = []
        func emit(_ k: String, _ v: Any) {
            let line = "M1GATE: \(k)=\(v)"
            print(line)
            lines.append(line)
            // Also persist: console streaming from a simulator/device is flaky,
            // a file in the container is not.
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? lines.joined(separator: "\n")
                    .write(to: dir.appendingPathComponent("m1gate.txt"), atomically: true, encoding: .utf8)
            }
        }

        do {
            let (wall, p) = try await PythonRuntime.shared.boot()
            guard p["ok"] as? Bool == true else {
                emit("boot_ok", false); emit("boot_error", p["error"] ?? "?"); return
            }
            emit("boot_ok", true)
            emit("wall_secs", String(format: "%.3f", wall))
            emit("import_secs", p["import_secs"] ?? "?")
            emit("cold_measurement", (p["cached"] as? Bool).map { !$0 } ?? false)
            emit("run", p["run"] ?? "?")
            emit("t_firstimport", p["t_firstimport"] ?? "?")
            emit("t_pure", p["t_pure"] ?? "?")
            emit("t_ext", p["t_ext"] ?? "?")
            emit("t_stdlib", p["t_stdlib"] ?? "?")
            emit("t_ytdlp", p["t_ytdlp"] ?? "?")
            if let e = p["ext_modules_loaded"] as? [String: Any] {
                emit("ext_modules_loaded", e["count"] ?? "?")
                if let j = try? JSONSerialization.data(withJSONObject: e["sample"] ?? [], options: []),
                   let str = String(data: j, encoding: .utf8) { emit("ext_sample", str) }
            }
            emit("bytecode", p["bytecode"] ?? "?")
            emit("qjs_version", p["qjs_version"] ?? "absent")
            emit("jsc_provider", p["jsc_provider"] ?? "?")
            if let d = p["ext_detail"] as? [String: Any],
               let j = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
               let str = String(data: j, encoding: .utf8) { emit("ext_detail", str) }
            if let d = p["pure_detail"] as? [String: Any],
               let j = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
               let str = String(data: j, encoding: .utf8) { emit("pure_detail", str) }
            emit("python", p["python"] ?? "?")
            emit("ytdlp", p["ytdlp_version"] ?? "?")
            emit("platform", p["platform"] ?? "?")
            emit("ca_bundle_found", (p["ca_bundle"] as? String)?.isEmpty == false)
        } catch {
            emit("boot_ok", false); emit("boot_error", error.localizedDescription); return
        }

        // Written here, not after the probes: the probes do network I/O that can
        // block for a long timeout, and a launch killed during one previously
        // lost its measurement entirely.
        let kv = parse(lines)
        appendHistory("run \(kv["run"] ?? "?") [\(hostTag())]\(isDebuggerAttached() ? " [debugger]" : "")"
            + (trigger == "launch" ? "" : " [warm:\(trigger)]")
            + "  import=\(kv["import_secs"] ?? "?")s"
            + "  first=\(kv["t_firstimport"] ?? "?")"
            + "  ext=\(kv["t_ext"] ?? "?")"
            + "  pure=\(kv["t_pure"] ?? "?")"
            + "  yt=\(kv["t_ytdlp"] ?? "?")")

        var passes = 0
        var hotPath = ""
        var ytURL = ""
        var ytHeaders: [String: String] = [:]
        for p in probes {
            var arg = p.url
            if let f = p.format,
               let j = try? JSONSerialization.data(withJSONObject: ["url": p.url, "format": f]),
               let str = String(data: j, encoding: .utf8) { arg = str }
            do {
                let d = try await PythonRuntime.shared.resolve(arg)
                let ok = d["ok"] as? Bool ?? false
                emit("\(p.name)_ok", ok)
                if ok {
                    passes += 1
                    emit("\(p.name)_secs", d["secs"] ?? "?")
                    emit("\(p.name)_extractor", d["extractor"] ?? "?")
                    emit("\(p.name)_format", d["format_id"] ?? "?")
                    emit("\(p.name)_acodec", d["acodec"] ?? "?")
                    emit("\(p.name)_urllen", (d["url"] as? String)?.count ?? 0)
                    emit("\(p.name)_solves", d["solves"] ?? "?")
                    if p.name == "youtube" {
                        hotPath = "  youtube=\(d["secs"] ?? "?")s solves=\(d["solves"] ?? "?")"
                        ytURL = (d["url"] as? String) ?? ""
                        ytHeaders = (d["http_headers"] as? [String: String]) ?? [:]
                    }
                } else {
                    emit("\(p.name)_stage", d["stage"] ?? "?")
                    emit("\(p.name)_error", (d["error"] as? String)?.prefix(140) ?? "?")
                }
            } catch {
                emit("\(p.name)_ok", false)
                emit("\(p.name)_error", error.localizedDescription)
            }
        }
        emit("probes_passed", "\(passes)/\(probes.count)")

        appendHistory("        probes=\(passes)/\(probes.count)\(hotPath)")

        // M2 gate: force a client that actually requires an n-sig solve.
        // The default (visionos) client needs no JS challenge, so an ordinary
        // resolve never exercises QuickJS at all.
        do {
            let b = try await PythonRuntime.shared.call("bench_jschallenge")
            let ok = b["ok"] as? Bool ?? false
            emit("m2_solved", ok)
            emit("m2_solves", b["solves"] ?? "?")
            emit("m2_js_bytes", b["js_bytes"] ?? "?")
            emit("m2_solve_secs", b["solve_secs"] ?? "?")
            emit("m2_total_secs", b["total_secs"] ?? "?")
            emit("m2_qjs", b["qjs"] ?? "?")
            appendHistory("        m2: solves=\(b["solves"] ?? "?") "
                + "solve=\(b["solve_secs"] ?? "?")s js=\(b["js_bytes"] ?? "?")B")
        } catch {
            emit("m2_solved", false)
            emit("m2_error", error.localizedDescription)
        }
        // M4: can AVPlayer actually play what we resolved? itag 140 is a
        // dash-branded MP4 (ftypdash) and this was flagged at M0 as the
        // largest untested assumption in the chain. Cheapest strategy first.
        if ytURL.isEmpty {
            emit("m4_skipped", "no youtube url resolved")
        } else {
            var anyPlayed = false
            for strat in PlaybackProbe.Strategy.allCases {
                let r = await PlaybackProbe.probe(url: ytURL, headers: ytHeaders, strategy: strat)
                for k in r.keys.sorted() where k != "strategy" {
                    emit("m4_\(strat.rawValue)_\(k)", r[k] ?? "?")
                }
                if r["playing"] == "true" { anyPlayed = true }
            }
            emit("m4_playable", anyPlayed)
            appendHistory("        m4: playable=\(anyPlayed)")
        }
        // M4: drive the real AudioPlayer, not a standalone AVPlayer.
        let pr = await PlayerProbe.run(
            sourceURL: "https://www.youtube.com/watch?v=iG9CE55wbtY",
            secondURL: "https://www.youtube.com/watch?v=WRS9Gek4V5Q")
        for k in pr.keys.sorted() { emit("player_\(k)", pr[k] ?? "?") }
        appendHistory("        player: first_audio=\(pr["first_audio_secs"] ?? "?")s "
            + "fmt=\(pr["format"] ?? "?") np=\(pr["np_title"] != "MISSING" ? "ok" : "MISSING") "
            + "prefetch=\(pr["prefetched_next"] ?? "-")")
        emit("done", true)
    }
}
