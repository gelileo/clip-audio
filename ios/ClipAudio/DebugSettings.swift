import Foundation

/// Developer-only switches. Off by default so an ordinary launch is clean.
enum DebugSettings {
    private static let selfTestKey = "clipaudio.debug.selfTestOnLaunch"

    /// When on, the milestone self-test runs at launch. It drives real
    /// playback — queueing and playing its own tracks — so it must stay off
    /// for normal use.
    ///
    /// Cold-start numbers (interpreter init, yt-dlp import) are only valid
    /// from a launch run, because the first import is measured once per
    /// process. That is why this is a launch flag and not just a button.
    static var selfTestOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: selfTestKey) }
        set { UserDefaults.standard.set(newValue, forKey: selfTestKey) }
    }
}
