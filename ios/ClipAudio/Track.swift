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
        /// Mapped to PRD §10's failure ladder so the UI can say what broke.
        var userMessage: String {
            switch stage {
            case "NO_COMPATIBLE_FORMAT": return "No compatible audio format"
            case "IMPORT", "BRIDGE":     return "Extraction engine problem"
            case "EXTRACT":
                let d = detail.lowercased()
                if d.contains("private") || d.contains("unavailable") { return "Video unavailable" }
                if d.contains("sign in") || d.contains("age")        { return "Sign-in required" }
                if d.contains("geo")                                 { return "Not available in your region" }
                if d.contains("timed out") || d.contains("urlopen")  { return "Network problem" }
                return "Can't read this link"
            default: return "Couldn't load this"
            }
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
