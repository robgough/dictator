import Foundation

/// Quiets other audio while Dictator is actively listening, restores it
/// when the recording ends. Owned by `Pipeline`, called at the two
/// transitions in/out of the `.recording` state.
///
/// Mode is captured at `start()` time and frozen for the matching
/// `stop()`. If the user toggles the setting mid-recording, the same
/// action that started runs in reverse — we never want to leave the
/// system volume low or the music paused because the setting flipped.
///
/// `stop()` is idempotent: calling it without a prior `start()` is a
/// no-op, which means Pipeline can call it from every exit path
/// (cancel, unexpected stop, normal finish) without bookkeeping.
@MainActor
final class AudioInterrupter {
    /// The fraction of the user's existing volume we drop to in
    /// `lowerVolume` mode. Tested informally: 20% is quiet enough that
    /// dictating over music feels comfortable without making the room
    /// silent (the silence is itself jarring on a quick 3-second
    /// dictation).
    private static let lowerVolumeTarget: Float = 0.2

    /// State captured at `start()` so `stop()` knows what to undo.
    private enum Active {
        case loweredVolume(restoreTo: Float)
        case pausedMedia(app: MediaController.SupportedApp)
    }
    private var active: Active?

    func start(mode: AudioInterruption) {
        // Idempotent: if a previous recording somehow didn't tear down
        // (shouldn't happen — but if it did, the wrong thing to do is
        // stack a second action on top). Restore first, then re-engage.
        if active != nil { stop() }

        switch mode {
        case .off:
            return
        case .lowerVolume:
            engageDuck()
        case .pauseMedia:
            engagePause()
        case .auto:
            // Duck when this Mac's current output supports it (built-in, wired,
            // Bluetooth); fall back to pausing when it doesn't (USB / Thunderbolt
            // interfaces whose driver owns the gain, HDMI, AirPlay, aggregates).
            // Probed every recording, so swapping output devices is handled
            // automatically. Picks exactly one branch, so restore stays simple.
            if SystemOutputVolume.isSettable() {
                engageDuck()
            } else {
                engagePause()
            }
        }
    }

    /// Drop the system output volume to the target, recording the original for
    /// restore. Bails (no `active` recorded) when the device exposes no settable
    /// volume — typical for external interfaces — rather than synthesising a fake
    /// restore value, and when the user is already below the target (restoring
    /// would push the volume *up* on stop, worse than doing nothing).
    private func engageDuck() {
        guard let original = SystemOutputVolume.current() else { return }
        guard original > Self.lowerVolumeTarget else { return }
        if SystemOutputVolume.set(Self.lowerVolumeTarget) {
            active = .loweredVolume(restoreTo: original)
        }
    }

    /// Pause media, but only if something is actually playing — a blanket
    /// pause/play would spuriously *start* music after a quiet dictation. Scoped
    /// to Spotify and Music; see MediaController for why broader coverage isn't
    /// free on macOS 15.4+.
    private func engagePause() {
        if let app = MediaController.appCurrentlyPlaying() {
            MediaController.pause(app: app)
            active = .pausedMedia(app: app)
        }
    }

    func stop() {
        guard let active else { return }
        self.active = nil
        switch active {
        case .loweredVolume(let restoreTo):
            SystemOutputVolume.set(restoreTo)
        case .pausedMedia(let app):
            MediaController.play(app: app)
        }
    }
}
