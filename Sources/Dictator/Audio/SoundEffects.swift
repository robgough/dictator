import Foundation
import AudioToolbox
@preconcurrency import AVFoundation

/// Plays the arm / start / stop / done audio cues as macOS *system sounds*.
///
/// Why system sounds rather than our own `AVAudioEngine`? Starting an
/// `AVAudioEngine` opens a fresh IO context on the output device; coreaudiod
/// then reconfigures the device's IO cycle to splice our stream in, and on a
/// shared-clock duplex interface (Scarlett, most USB audio boxes) the output
/// audibly *gaps for a beat* while it does — every app's playback dips the
/// moment Dictator launches (prewarm) or plays its first cue after the engine
/// had idle-stopped. `AudioServicesPlaySystemSound` renders the cue inside
/// coreaudiod's already-running system-sound path, so our process never opens
/// an IO context: no device reconfiguration, no dip.
///
/// It also retires the whole reason the old engine had to idle-stop. A
/// persistent output engine on a duplex device pulled the device's *input*
/// streams into its IO context, so coreaudiod attributed recording to us and
/// pinned the orange mic indicator while the app sat idle. We never hold an IO
/// context now, so that failure mode is structurally impossible — there's no
/// prewarm engine, no idle-stop, and no configuration-change handler to get
/// wrong.
///
/// The tones are synthesised in-process (`SoundSynth`, one `SoundTheme`'s
/// worth at a time — the user picks the set in Settings). They're rendered to
/// small CAF files in Application Support once per synthesis version,
/// registered as `SystemSoundID`s, and replayed from disk. `preview(_:)`
/// registers any other theme on demand so Settings can play a sample of it.
///
/// Trade-offs inherited from the system-sound path, all acceptable for short
/// UI cues: playback uses the user's *alert* volume and the *"Play sound
/// effects through"* output device (usually the same as the main output), and
/// honours the system "play user-interface sound effects" toggle. Overlapping
/// cues mix rather than interrupt — moot here, since cues are sequential and
/// well under a second.
final class SoundEffects: @unchecked Sendable {
    static let shared = SoundEffects()

    /// Bump when `SoundSynth` changes so stale cached CAFs aren't reused.
    /// Old-version files linger harmlessly (a few KB each).
    /// v2 (2026-09): glass palette, stereo, reverb tail.
    /// v3 (2026-09): themed sets, files named `<theme>-<cue>`.
    private static let cacheVersion = 3

    private let format: AVAudioFormat

    /// The set Settings has chosen. All access on `queue`.
    private var theme: SoundTheme = .soft
    /// Live cue handles, registered for `preparedTheme`. All access on `queue`.
    private var liveIDs: [SoundSynth.Cue: SystemSoundID] = [:]
    private var preparedTheme: SoundTheme?
    /// Handles registered for sampling from Settings, kept for the session so
    /// repeated plays are instant. Separate from `liveIDs` so switching the
    /// live theme never disposes a handle a preview is about to use.
    private var previewIDs: [SoundTheme: [SoundSynth.Cue: SystemSoundID]] = [:]

    /// Serial queue ordering setup and playback. `AudioServicesPlaySystemSound`
    /// is non-blocking (it hands the sound to the system sound server and
    /// returns), so this never backs up; it exists purely to isolate the
    /// render/register work from the cue calls without a lock. The first
    /// launch renders four tiny files here off the main thread; later launches
    /// just re-register the cached files.
    private let queue = DispatchQueue(label: "Dictator.SoundEffects", qos: .userInitiated)

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Double(SoundSynth.sampleRate), channels: 2)!
    }

    /// Point the live cues at `theme`. Cheap when unchanged; otherwise drops
    /// the current registrations and lets the next cue (or `prewarm`)
    /// re-prepare against the new set.
    func setTheme(_ theme: SoundTheme) {
        queue.async { [weak self] in
            guard let self, self.theme != theme else { return }
            self.theme = theme
            self.disposeLiveLocked()
        }
    }

    /// Render + register the cues ahead of the first hotkey press so the arm
    /// chime is instant. Unlike the old engine prewarm this opens no audio
    /// device IO — system sounds render in coreaudiod — so it can neither dip
    /// other audio nor pin the mic indicator. Best-effort; play() prepares
    /// lazily too, so a missed prewarm only costs the first cue a beat.
    func prewarm() {
        queue.async { [weak self] in self?.prepareLocked() }
    }

    func playArm()   { play(.arm) }
    func playStart() { play(.start) }
    func playStop()  { play(.stop) }
    func playDone()  { play(.done) }

    /// Play a sample of `theme` — arm, start, stop, done in sequence, spaced
    /// roughly as a real dictation spaces them. Doesn't touch the live theme
    /// and ignores the "Play sounds" switch: the user pressed a play button.
    func preview(_ theme: SoundTheme) {
        queue.async { [weak self] in
            guard let self else { return }
            let ids: [SoundSynth.Cue: SystemSoundID]
            if let cached = self.previewIDs[theme] {
                ids = cached
            } else {
                guard let made = try? self.registerAll(theme: theme) else { return }
                self.previewIDs[theme] = made
                ids = made
            }
            let schedule: [(SoundSynth.Cue, Double)] = [(.arm, 0), (.start, 0.35), (.stop, 1.05), (.done, 1.55)]
            for (cue, delay) in schedule {
                guard let id = ids[cue] else { continue }
                self.queue.asyncAfter(deadline: .now() + delay) {
                    AudioServicesPlaySystemSound(id)
                }
            }
        }
    }

    private func play(_ cue: SoundSynth.Cue) {
        // Hop onto the serial queue so the caller (the hotkey path) returns
        // immediately and we never touch the IDs off-queue.
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareLocked()
            if let id = self.liveIDs[cue] {
                AudioServicesPlaySystemSound(id)
            }
        }
    }

    /// Render any missing CAFs for the live theme and register every cue.
    /// Idempotent per theme. Must run on `queue`.
    private func prepareLocked() {
        if preparedTheme == theme, !liveIDs.isEmpty { return }
        disposeLiveLocked()
        do {
            liveIDs = try registerAll(theme: theme)
            preparedTheme = theme
        } catch {
            // No output device, unwritable cache, or registration refusal:
            // skip cues silently, same best-effort contract the engine had.
            liveIDs = [:]
            preparedTheme = nil
        }
    }

    private func disposeLiveLocked() {
        for id in liveIDs.values { AudioServicesDisposeSystemSoundID(id) }
        liveIDs = [:]
        preparedTheme = nil
    }

    private func registerAll(theme: SoundTheme) throws -> [SoundSynth.Cue: SystemSoundID] {
        let dir = Self.cueDirectory()
        var ids: [SoundSynth.Cue: SystemSoundID] = [:]
        for cue in SoundSynth.Cue.allCases {
            ids[cue] = try register(cue, theme: theme, in: dir)
        }
        return ids
    }

    /// Render `cue` to `<dir>/<theme>-<cue>.v<cacheVersion>.caf` if it isn't
    /// already there, then create a `SystemSoundID` for it. Must run on `queue`.
    private func register(_ cue: SoundSynth.Cue, theme: SoundTheme, in dir: URL) throws -> SystemSoundID {
        let url = dir.appendingPathComponent("\(theme.rawValue)-\(cue.rawValue).v\(Self.cacheVersion).caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            // 16-bit LinearPCM CAF — ample for a UI cue. The buffer stays
            // Float32 in memory; AVAudioFile converts on write.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer(for: cue, theme: theme))
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return id
    }

    /// `~/Library/Application Support/Dictator/SoundCues/`. Mirrors the
    /// resolution `MicLog` / `ModelStorage` use.
    private static func cueDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Dictator/SoundCues", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies `SoundSynth`'s rendered channels into a PCM buffer in `format`.
    private func buffer(for cue: SoundSynth.Cue, theme: SoundTheme) -> AVAudioPCMBuffer {
        let channels = SoundSynth.render(cue, theme: theme)
        let frameCount = AVAudioFrameCount(channels.first?.count ?? 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 1))!
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else { return buffer }
        for c in 0..<Int(format.channelCount) {
            let source = channels[min(c, channels.count - 1)]
            source.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    data[c].update(from: base, count: Int(frameCount))
                }
            }
        }
        return buffer
    }
}
