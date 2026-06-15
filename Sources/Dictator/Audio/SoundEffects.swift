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
/// The tones are still synthesised in-process (the bell / wood partial design
/// below — that's the polish). They're rendered to small CAF files in
/// Application Support once per synthesis version, registered as
/// `SystemSoundID`s, and replayed from disk.
///
/// Trade-offs inherited from the system-sound path, all acceptable for short
/// UI cues: playback uses the user's *alert* volume and the *"Play sound
/// effects through"* output device (usually the same as the main output), and
/// honours the system "play user-interface sound effects" toggle. Overlapping
/// cues mix rather than interrupt — moot here, since cues are sequential and
/// ≤0.4 s.
final class SoundEffects: @unchecked Sendable {
    static let shared = SoundEffects()

    /// Bump when the synthesis below changes so stale cached CAFs aren't
    /// reused. Old-version files linger harmlessly (a few KB each).
    private static let cacheVersion = 1

    private let format: AVAudioFormat

    /// Registered system-sound handles. All access on `queue`.
    private var armID: SystemSoundID = 0
    private var startID: SystemSoundID = 0
    private var stopID: SystemSoundID = 0
    private var doneID: SystemSoundID = 0
    /// True once the CAFs are rendered + registered. All access on `queue`.
    private var prepared = false

    /// Serial queue ordering setup and playback. `AudioServicesPlaySystemSound`
    /// is non-blocking (it hands the sound to the system sound server and
    /// returns), so this never backs up; it exists purely to isolate the
    /// one-time render/register from the cue calls without a lock. The first
    /// launch renders four tiny files here off the main thread; later launches
    /// just re-register the cached files.
    private let queue = DispatchQueue(label: "Dictator.SoundEffects", qos: .userInitiated)

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    }

    /// Render + register the cues ahead of the first hotkey press so the arm
    /// chime is instant. Unlike the old engine prewarm this opens no audio
    /// device IO — system sounds render in coreaudiod — so it can neither dip
    /// other audio nor pin the mic indicator. Best-effort; play() prepares
    /// lazily too, so a missed prewarm only costs the first cue a beat.
    func prewarm() {
        queue.async { [weak self] in self?.prepareLocked() }
    }

    func playArm()   { play(\.armID) }
    func playStart() { play(\.startID) }
    func playStop()  { play(\.stopID) }
    func playDone()  { play(\.doneID) }

    private func play(_ id: KeyPath<SoundEffects, SystemSoundID>) {
        // Hop onto the serial queue so the caller (the hotkey path) returns
        // immediately and we never touch `prepared` / the IDs off-queue.
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareLocked()
            guard self.prepared else { return }
            AudioServicesPlaySystemSound(self[keyPath: id])
        }
    }

    /// Render any missing CAFs and register every cue. Idempotent — runs its
    /// work once and no-ops thereafter. Must run on `queue`.
    private func prepareLocked() {
        guard !prepared else { return }
        let dir = Self.cueDirectory()
        do {
            armID   = try register("arm",   Self.makeTone(format: format, frequency: 370, partials: Self.woodPartials,  attackSeconds: 0.025, durationMS: 180, amplitude: 0.12), in: dir)  // F#4, woody
            startID = try register("start", Self.makeTone(format: format, frequency: 587, partials: Self.chimePartials, attackSeconds: 0.020, durationMS: 400, amplitude: 0.16), in: dir)  // D5
            stopID  = try register("stop",  Self.makeTone(format: format, frequency: 440, partials: Self.chimePartials, attackSeconds: 0.018, durationMS: 400, amplitude: 0.16), in: dir)  // A4
            doneID  = try register("done",  Self.makeTone(format: format, frequency: 880, partials: Self.chimePartials, attackSeconds: 0.014, durationMS: 320, amplitude: 0.11), in: dir)  // A5, quieter
            prepared = true
        } catch {
            // No output device, unwritable cache, or registration refusal:
            // skip cues silently, same best-effort contract the engine had.
            prepared = false
        }
    }

    /// Write `buffer` to `<dir>/<name>.v<cacheVersion>.caf` if it isn't already
    /// there, then create a `SystemSoundID` for it. Must run on `queue`.
    private func register(_ name: String, _ buffer: AVAudioPCMBuffer, in dir: URL) throws -> SystemSoundID {
        let url = dir.appendingPathComponent("\(name).v\(Self.cacheVersion).caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            // 16-bit LinearPCM CAF — ample for a UI cue. The buffer stays
            // Float32 in memory; AVAudioFile converts on write.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
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

    // MARK: - Synthesis

    private struct Partial {
        let ratio: Float        // multiple of the fundamental (non-integer is fine)
        let gain: Float         // relative amplitude at t=0
        let decay: Float        // higher = faster fall-off
    }

    /// Warm chime partials — purely harmonic (no inharmonic strike tone),
    /// with a quiet sub-octave for body. The sub-octave is the warmth lever:
    /// it adds the lower-frequency resonance the ear reads as "real wooden
    /// instrument" rather than "synthesised tone". The 3× partial (perfect
    /// 12th) replaces a 4× double-octave because human-vocal/orchestral
    /// instruments emphasise 3×, so the ear hears it as natural sparkle
    /// rather than synth-bright. `decay` is normalised to buffer duration,
    /// so end-of-buffer amplitude is exp(-decay) — keep it ≥ 4 so residual
    /// is below 2% before the tail-fade cleans up.
    private static let chimePartials: [Partial] = [
        Partial(ratio: 0.500, gain: 0.18, decay: 4.0),   // sub-octave body
        Partial(ratio: 1.000, gain: 1.00, decay: 4.5),   // fundamental
        Partial(ratio: 2.000, gain: 0.22, decay: 6.0),   // octave warmth
        Partial(ratio: 3.000, gain: 0.07, decay: 8.5),   // perfect 12th sparkle
    ]

    /// Woody / muted partial structure. Fundamental + light sub-octave for
    /// body + a touch of octave. No inharmonic shimmer, no high sparkle,
    /// faster overall decay. Feels like a soft mallet on a damped wooden
    /// block — distinct enough from the chimes to read as a different
    /// category of event.
    private static let woodPartials: [Partial] = [
        Partial(ratio: 0.500, gain: 0.10, decay: 4.5),
        Partial(ratio: 1.000, gain: 1.00, decay: 5.0),
        Partial(ratio: 2.000, gain: 0.15, decay: 6.5),
    ]

    private static func makeTone(format: AVAudioFormat,
                                 frequency: Float,
                                 partials: [Partial],
                                 attackSeconds: Float,
                                 durationMS: Int,
                                 amplitude: Float) -> AVAudioPCMBuffer {
        let sampleRate = Float(format.sampleRate)
        let frameCount = AVAudioFrameCount(sampleRate * Float(durationMS) / 1000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        guard let channels = buffer.floatChannelData else { return buffer }
        let channelCount = Int(format.channelCount)

        let durationSeconds = Float(durationMS) / 1000
        let attackFraction = attackSeconds / durationSeconds
        // Final 25 ms gets a cosine fade-out to zero so however the partials
        // are sitting at end-of-buffer they don't produce a hard cut. Cheap
        // hygiene that lets us pick any decay value without an audible click.
        let tailFadeSeconds: Float = 0.025
        let tailFadeStart = max(0, durationSeconds - tailFadeSeconds)

        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            let normalized = t / durationSeconds // 0…1

            // Raised-cosine attack to eliminate the onset click of a hard
            // ramp; held flat at 1.0 after the attack so the per-partial
            // exponential decays handle the rest.
            let attackEnv: Float
            if t < attackSeconds {
                attackEnv = 0.5 - 0.5 * cosf(.pi * t / attackSeconds)
            } else {
                attackEnv = 1.0
            }
            let tailEnv: Float
            if t >= tailFadeStart {
                let into = (t - tailFadeStart) / tailFadeSeconds
                tailEnv = 0.5 + 0.5 * cosf(.pi * min(into, 1))
            } else {
                tailEnv = 1.0
            }
            let decayPhase = max(0, normalized - attackFraction)

            var sample: Float = 0
            for p in partials {
                let env = expf(-p.decay * decayPhase)
                sample += p.gain * env * sinf(2 * .pi * frequency * p.ratio * t)
            }

            let s = sample * attackEnv * tailEnv * amplitude
            for c in 0..<channelCount { channels[c][i] = s }
        }
        return buffer
    }
}
