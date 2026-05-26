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

    init() {}

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
        currentTime = 0
        duration = 0
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard micPlayer != nil || systemPlayer != nil else { return }
        // If we're at the end, start over. Each rewind is also a seek
        // because the user might have scrubbed all the way to the right.
        if currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        micPlayer?.play()
        systemPlayer?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        micPlayer?.pause()
        systemPlayer?.pause()
        isPlaying = false
        stopTimer()
        // Latch the visible currentTime to whichever player has the most
        // accurate clock — the system track is the canonical one (mic may
        // be missing on an imported meeting).
        currentTime = systemPlayer?.currentTime ?? micPlayer?.currentTime ?? currentTime
    }

    /// Seek both players. We clamp to [0, duration] so a slider drag past
    /// the end just snaps to the end.
    func seek(to seconds: TimeInterval) {
        let t = max(0, min(seconds, duration))
        // AVAudioPlayer's currentTime is direct — assigning it seeks.
        // For tracks shorter than `duration`, clamp to that player's own
        // duration so we don't blow past the file.
        if let p = micPlayer {
            p.currentTime = min(t, p.duration)
        }
        if let p = systemPlayer {
            p.currentTime = min(t, p.duration)
        }
        currentTime = t
    }

    private func startTimer() {
        stopTimer()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isPlaying else { return }
                let t = self.systemPlayer?.currentTime ?? self.micPlayer?.currentTime ?? 0
                self.currentTime = t
                let micDone = self.micPlayer.map { !$0.isPlaying } ?? true
                let sysDone = self.systemPlayer.map { !$0.isPlaying } ?? true
                if micDone && sysDone {
                    self.isPlaying = false
                    self.currentTime = self.duration
                    return
                }
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}
