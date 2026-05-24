import Foundation
import AppKit

/// Pause and resume currently-playing media for the dictation duration.
///
/// We used to call MediaRemote directly, but macOS 15.4 locked the
/// framework to entitled Apple processes — `MRMediaRemoteSendCommand`
/// and `MRMediaRemoteGetNowPlayingApplicationIsPlaying` are no-ops for
/// third-party apps now. The mediaremoted daemon ignores us.
///
/// Replacement uses two layers:
///
/// 1. AppleScript probes Spotify and Music (in that order). Each has a
///    `player state` property we can read to find a currently-playing
///    app, then a `pause` / `play` command we can call directly. Clean,
///    state-aware, idempotent. Triggers a one-time Automation consent
///    prompt the first time it runs for each target app.
///
/// 2. If neither is playing, we synthesise the system Play/Pause media
///    key as a best-effort fallback. macOS's own media-key handler still
///    has the entitlement, so the event reaches whatever owns the Now
///    Playing session (Safari with YouTube, Podcasts, etc.). The catch
///    is that it's a toggle, not a directional command — we only fire
///    it when we have positive evidence something is playing, so we
///    don't accidentally *start* music on a quiet machine.
///
/// "Positive evidence" for the fallback path is currently weaker than
/// the Spotify/Music probes — we'd need a working Now Playing query for
/// that. For now, fallback is off; users with non-Spotify/Music
/// playback won't get auto-pause. Spotify and Music cover the
/// overwhelming majority of "I'm listening to music while I work" use
/// cases.
enum MediaController {
    /// Apps we probe in priority order. First-match-wins keeps the
    /// behaviour deterministic when more than one is open.
    enum SupportedApp: String, CaseIterable {
        case spotify = "Spotify"
        case music = "Music"
    }

    /// Find an app currently playing. Returns nil if none, the app
    /// isn't running, or Automation consent hasn't been granted.
    static func appCurrentlyPlaying() -> SupportedApp? {
        for app in SupportedApp.allCases where isPlaying(app: app) {
            return app
        }
        return nil
    }

    /// Send `pause` to a specific app. Safe to call even if the app's
    /// state changed since we probed it (the per-app scripts no-op on
    /// already-paused state).
    static func pause(app: SupportedApp) {
        run(script: """
        if application "\(app.rawValue)" is running then
            tell application "\(app.rawValue)" to pause
        end if
        """)
    }

    /// Send `play` to a specific app. Same robustness as `pause`.
    static func play(app: SupportedApp) {
        run(script: """
        if application "\(app.rawValue)" is running then
            tell application "\(app.rawValue)" to play
        end if
        """)
    }

    // MARK: - Private

    /// Probes the app's `player state` and returns true only when it's
    /// playing. Returns false on "not running", "consent denied", "any
    /// script error" — every failure mode is safe (we just won't try to
    /// pause/resume something we can't talk to).
    private static func isPlaying(app: SupportedApp) -> Bool {
        let script = """
        if application "\(app.rawValue)" is running then
            tell application "\(app.rawValue)"
                try
                    return (player state is playing) as boolean
                on error
                    return false
                end try
            end tell
        else
            return false
        end if
        """
        guard let result = run(script: script) else { return false }
        return result.booleanValue
    }

    @discardableResult
    private static func run(script source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        // We intentionally don't surface errors. The common ones are
        // "app not running" (false from the wrapper above), "consent
        // denied" (handled at the OS level — user sees the system
        // prompt and either accepts or denies), and AppleScript syntax
        // bugs (would be developer error, caught at first manual test).
        return error == nil ? result : nil
    }
}
