import Foundation

/// A thing the user asked to play.
///
/// `sourceURL` is the only durable identity. Resolved stream URLs expire
/// (~6h) and are tied to the requesting client, so they are never persisted
/// and never treated as a stable handle (PRD C8).
struct Track: Identifiable, Hashable {
    let id = UUID()
    let sourceURL: String

    var title: String?
    var uploader: String?
    var duration: Double?
    var artworkURL: String?

    // Ephemeral. Dropped on persistence, refreshed on demand.
    var streamURL: String?
    var formatID: String?
    var resolvedAt: Date?

    var displayTitle: String { title ?? sourceURL }

    /// Resolved URLs are short-lived; treat anything older as suspect rather
    /// than waiting for a 403 mid-playback.
    var isResolutionStale: Bool {
        guard let at = resolvedAt else { return true }
        return Date().timeIntervalSince(at) > 3 * 3600
    }

    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// How a source link becomes something AVPlayer can open.
///
/// Deliberately an interface. PRD §13 lists YouTube's SABR migration as the
/// project's existential risk: if plain stream URLs disappear, a UMP/SABR
/// fetcher feeding a local server slots in here without the player layer
/// knowing (and the same seam absorbs a local HLS manifest for the ~20% of
/// videos with no HLS rendition — M4).
protocol StreamSource: Sendable {
    func resolve(_ sourceURL: String) async throws -> Track
}

/// The current implementation: on-device yt-dlp via the embedded interpreter.
struct YtDlpStreamSource: StreamSource {
    struct ResolveError: LocalizedError {
        let stage: String, detail: String
        var errorDescription: String? { detail }
        private enum Kind {
            case noFormat, engine, unavailable, signIn, region, network, unreadable, other
        }
        private var kind: Kind {
            switch stage {
            case "NO_COMPATIBLE_FORMAT": return .noFormat
            case "IMPORT", "BRIDGE":     return .engine
            case "EXTRACT":
                let d = detail.lowercased()
                if d.contains("private") || d.contains("unavailable") { return .unavailable }
                if d.contains("sign in") || d.contains("age")        { return .signIn }
                if d.contains("geo")                                 { return .region }
                if d.contains("timed out") || d.contains("urlopen")  { return .network }
                return .unreadable
            default: return .other
            }
        }
        /// Mapped to PRD §10's failure ladder so the UI can say what broke.
        var userMessage: String {
            switch kind {
            case .noFormat:    return "No compatible audio format"
            case .engine:      return "Extraction engine problem"
            case .unavailable: return "Video unavailable"
            case .signIn:      return "Sign-in required"
            case .region:      return "Not available in your region"
            case .network:     return "Network problem"
            case .unreadable:  return "Can't read this link"
            case .other:       return "Couldn't load this"
            }
        }
        /// True when retrying will not help: the item is gone or blocked for
        /// this user. Transient problems (network, engine) are not definitive.
        ///
        /// Deliberately stricter than `kind`: this drives `markUnavailable`,
        /// so a false positive hides a healthy item. Transient signals are
        /// checked first and can never fall through to "definitive".
        var isDefinitive: Bool {
            guard stage == "EXTRACT" else { return false }
            let d = detail.lowercased()
            let transient = ["http error 5", "service unavailable", "timed out", "timeout",
                             "urlopen", "temporarily", "connection", "network",
                             "try again", "too many requests", "http error 429"]
            if transient.contains(where: d.contains) { return false }
            let definitive = ["video unavailable", "this video is unavailable", "is private",
                              "private video", "not available in your country",
                              "not available in your region", "in your country",
                              "geo restrict", "geo-restrict"]
            return definitive.contains(where: d.contains)
        }
    }

    func resolve(_ sourceURL: String) async throws -> Track {
        let d = try await PythonRuntime.shared.resolve(sourceURL)
        guard d["ok"] as? Bool == true else {
            throw ResolveError(stage: (d["stage"] as? String) ?? "?",
                               detail: (d["error"] as? String) ?? "unknown")
        }
        var t = Track(sourceURL: sourceURL)
        t.title      = d["title"] as? String
        t.uploader   = d["uploader"] as? String
        t.duration   = d["duration"] as? Double
        t.artworkURL = d["thumbnail"] as? String
        t.streamURL  = d["url"] as? String
        t.formatID   = d["format_id"] as? String
        t.resolvedAt = Date()
        return t
    }
}
