import Foundation
@preconcurrency import AVFoundation

/// Plays back a meeting's mic + system tracks in sync. We load each
/// available CAF file into an `AVAudioPlayer`, start them in lock-step,
/// and report a single progress timeline. If only one track exists
/// (typically because it's an imported file, or the user deleted the
/// audio for storage reasons but kept the transcript), we just play the
/// one we have.
///
/// `AVAudioPlayer` is the right tool here even though we have two
/// instances: both files are short enough to load fully into memory, the
/// sync drift over a typical meeting length (~tens of milliseconds for
/// independent players started back-to-back on the same thread) is well
/// within "you can't tell" for speech playback. If we ever need
/// sample-accurate sync we'll lift this to AVAudioEngine.
@MainActor
@Observable
final class MeetingPlayer {
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var micPlayer: AVAudioPlayer?
    private var systemPlayer: AVAudioPlayer?
    private var timerTask: Task<Void, Never>?

    /// True between `beginScrub` and `endScrub` while the user drags the
    /// slider. Suspends the progress timer's writes to `currentTime` so the
    /// thumb follows the finger instead of fighting the playhead.
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var wasPlayingBeforeScrub = false

    /// Per-track speech intervals (sorted, merged) that drive playback
    /// ducking. Without headphones the mic track carries the speakers'
    /// bleed, so playing both tracks flat doubles every remote word into an
    /// unpleasant echo. While the system track has speech and the mic has
    /// none of its own, the mic is ducked hard; during genuine overlap it's
    /// ducked only partially so the user's interjection stays audible.
    @ObservationIgnored private var micSpeech: [(start: Double, end: Double)] = []
    @ObservationIgnored private var systemSpeech: [(start: Double, end: Double)] = []

    /// Baseline per-track volumes from loudness normalization — the two
    /// tracks' speech levels routinely differ several-fold (quiet mic vs
    /// digitally-hot call audio). AVAudioPlayer can only attenuate, so the
    /// LOUDER track is turned down toward the quieter one. Ducking
    /// multiplies on top of the mic baseline.
    @ObservationIgnored private var micBaseVolume: Float = 1
    @ObservationIgnored private var systemBaseVolume: Float = 1

    init() {}

    /// Wire the per-track speech timelines (from the meeting's track
    /// inspection data) into the ducking logic. Pass empty arrays for
    /// meetings without track data — both tracks then play flat, the old
    /// behaviour.
    func setSpeechIntervals(
        mic: [(start: Double, end: Double)],
        system: [(start: Double, end: Double)]
    ) {
        micSpeech = mic
        systemSpeech = system
        applyDucking(at: currentTime)
    }

    /// Balance the tracks from their measured speech levels so both sides
    /// of the call play back at roughly the same loudness. Clamped so a
    /// whisper-quiet measurement can't effectively mute the other track.
    func setTrackLevels(mic: Double?, system: Double?) {
        micBaseVolume = 1
        systemBaseVolume = 1
        if let mic, let system, mic > 0, system > 0 {
            let ratio = mic / system          // < 1 ⇒ mic is the quiet one
            if ratio < 1 {
                systemBaseVolume = Float(max(0.2, ratio))
            } else {
                micBaseVolume = Float(max(0.2, 1 / ratio))
            }
        }
        systemPlayer?.volume = systemBaseVolume
        applyDucking(at: currentTime)
    }

    /// Load the available tracks. `micURL` / `systemURL` may each be
    /// nil — typically only one when the meeting was imported or its
    /// audio files have been pruned. Returns `true` if at least one
    /// player came up.
    @discardableResult
    func load(micURL: URL?, systemURL: URL?) -> Bool {
        unload()
        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            micPlayer = try? AVAudioPlayer(contentsOf: micURL)
            micPlayer?.prepareToPlay()
        }
        if let systemURL, FileManager.default.fileExists(atPath: systemURL.path) {
            systemPlayer = try? AVAudioPlayer(contentsOf: systemURL)
            systemPlayer?.prepareToPlay()
        }
        duration = max(micPlayer?.duration ?? 0, systemPlayer?.duration ?? 0)
        currentTime = 0
        return micPlayer != nil || systemPlayer != nil
    }

    /// Stop any in-flight playback, release both players. Safe to call
    /// repeatedly.
    func unload() {
        stopTimer()
        micPlayer?.stop()
        systemPlayer?.stop()
        micPlayer = nil
        systemPlayer = nil
        isPlaying = false
        isScrubbing = false
        currentTime = 0
        duration = 0
        micSpeech = []
        systemSpeech = []
        micBaseVolume = 1
        systemBaseVolume = 1
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard micPlayer != nil || systemPlayer != nil else { return }
        // If we're sitting at the end, start over.
        if currentTime >= duration - 0.05 { currentTime = 0 }
        isPlaying = true
        // Align both players to the playhead and start whichever still has
        // audio left there. Setting isPlaying first lets positionPlayers kick
        // each track into play().
        positionPlayers(to: currentTime)
        startTimer()
    }

    func pause() {
        micPlayer?.pause()
        systemPlayer?.pause()
        isPlaying = false
        stopTimer()
        // `currentTime` is already fresh from the progress timer (updated
        // ≤50 ms ago), so we don't re-derive it from a player here — reading
        // back an exhausted track's clock would jump the playhead.
    }

    /// Seek both players. We clamp to [0, duration]; a track with no audio
    /// left at the target is paused rather than pinned to its end.
    func seek(to seconds: TimeInterval) {
        let t = max(0, min(seconds, duration))
        currentTime = t
        positionPlayers(to: t)
    }

    // MARK: - Scrubbing (slider drag)

    /// Slider drag began. Pause playback for the duration of the drag so the
    /// progress timer doesn't fight the thumb and we don't spray a seek at the
    /// players on every slider tick. The original play/pause state is restored
    /// in `endScrub`.
    func beginScrub() {
        guard !isScrubbing else { return }
        wasPlayingBeforeScrub = isPlaying
        isScrubbing = true
        micPlayer?.pause()
        systemPlayer?.pause()
        stopTimer()
        isPlaying = false
    }

    /// Slider value changed mid-drag. Move the visible playhead only — the
    /// players are repositioned once on release, which is cheaper and avoids
    /// audible stutter from seeking every frame.
    func scrub(to seconds: TimeInterval) {
        currentTime = max(0, min(seconds, duration))
    }

    /// Slider drag ended. Land the players at the final playhead and resume
    /// playback if we were playing when the drag started.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        if wasPlayingBeforeScrub {
            play() // positions both players to currentTime and starts them
        } else {
            positionPlayers(to: currentTime)
        }
        wasPlayingBeforeScrub = false
    }

    // MARK: - Player positioning

    /// Move each player to `t`. A track whose audio ends before `t` is paused
    /// instead of being pinned to its end: assigning `currentTime == duration`
    /// to a *playing* `AVAudioPlayer` makes it wrap back to 0 and audibly
    /// restart — that was the "scrub jumps to the beginning" bug when the mic
    /// and system tracks had different lengths. When we're playing, a track
    /// that has audio at `t` is (re)started so a backward seek revives a track
    /// that had already finished.
    private func positionPlayers(to t: TimeInterval) {
        for player in [micPlayer, systemPlayer].compactMap({ $0 }) {
            if t < player.duration - 0.01 {
                player.currentTime = t
                if isPlaying && !player.isPlaying { player.play() }
            } else {
                if player.isPlaying { player.pause() }
                player.currentTime = max(0, player.duration - 0.01)
            }
        }
        applyDucking(at: t)
    }

    // MARK: - Ducking

    /// Binary search: does any interval contain `t`?
    private nonisolated static func contains(_ intervals: [(start: Double, end: Double)], _ t: Double) -> Bool {
        var lo = 0, hi = intervals.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let iv = intervals[mid]
            if t < iv.start { hi = mid - 1 }
            else if t > iv.end { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    /// Set the mic player's volume for the playhead position: the
    /// normalization baseline, hard-ducked while only the remote side is
    /// talking (the mic holds nothing but bleed there), partially ducked
    /// during overlap.
    private func applyDucking(at t: TimeInterval) {
        guard let micPlayer else { return }
        var target = micBaseVolume
        if systemPlayer != nil, !systemSpeech.isEmpty, Self.contains(systemSpeech, t) {
            target *= Self.contains(micSpeech, t) ? 0.35 : 0.05
        }
        if abs(micPlayer.volume - target) > 0.01 {
            micPlayer.setVolume(target, fadeDuration: 0.08)
        }
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isPlaying, !self.isScrubbing else { return }
                let players = [self.micPlayer, self.systemPlayer].compactMap { $0 }
                let playing = players.filter { $0.isPlaying }
                // Both tracks done — even at different lengths, the longer one
                // finishing is what ends playback.
                if playing.isEmpty {
                    self.isPlaying = false
                    self.currentTime = self.duration
                    return
                }
                self.currentTime = playing.map { $0.currentTime }.max() ?? self.currentTime
                self.applyDucking(at: self.currentTime)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
