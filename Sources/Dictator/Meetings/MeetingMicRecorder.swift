import Foundation
@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import CoreMedia

/// Captures mic audio for a meeting via AVAudioEngine and writes it
/// directly to a CAF file as the buffers arrive. Runs alongside the
/// `MeetingAudioRecorder` (SCStream system audio) on its own input
/// engine so the two tracks are independent.
///
/// Why AVAudioEngine here and not AVCaptureSession like the dictation
/// recorder? Because `inputNode.setVoiceProcessingEnabled(true)` is the
/// only public path to macOS's built-in acoustic echo cancellation. AEC
/// is the whole point of this recorder: when the user isn't wearing
/// headphones on a video call, the Mac's speakers play the remote audio,
/// the mic picks it back up, and the merged transcript shows every
/// remote utterance twice — once correctly on the system track and once
/// incorrectly attributed to "Me" on the mic. AVCaptureSession on macOS
/// exposes no equivalent. The AVAudioEngine voice-processing AU
/// subtracts the playback reference signal from the captured stream
/// before the recorder ever sees it, so the bleed simply isn't in the
/// file. Dictation doesn't need this (it captures into the focused app,
/// not into a "what does the rest of the call sound like" timeline), so
/// it stays on AVCaptureSession where the device-swap robustness story
/// is better.
///
/// Writes LinearPCM Float32 mono to a `.caf` file at the device's native
/// sample rate. CAF is crash-safe (its data chunk uses a "-1 = read to
/// end" length sentinel); a truncated file from a Dictator crash is still
/// fully decodable up to the last buffer that hit disk.
@MainActor
final class MeetingMicRecorder {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var running = false
    private var configChangeObserver: NSObjectProtocol?

    /// Snapshot of the start parameters so a mid-recording device swap
    /// (AirPods connect, USB mic unplugged, hub power-cycle) can rebuild
    /// the engine against the new active input without dragging the
    /// caller through another `start()` call.
    private var lastPreferredDevice: AudioDevice?
    private var lastEchoCancellation: MeetingMicEchoCancellation = .auto
    /// Whether the most-recent engine bring-up actually enabled voice
    /// processing. Surfaced via `voiceProcessingActive` so the UI / tests
    /// can confirm what landed (the resolved-from-`.auto` decision isn't
    /// otherwise visible).
    private(set) var voiceProcessingActive: Bool = false

    private(set) var fileURL: URL?
    /// True once at least one buffer made it to disk.
    private(set) var didCapture: Bool = false

    /// 0…1 RMS reported on the main actor for every captured buffer.
    var onLevel: (@MainActor (Float) -> Void)?

    init() {}

    /// Build an AVAudioEngine against the user's preferred input device
    /// (falls back to system default) and start writing. Throws on
    /// permission denied or no input device. Matches the dictation flow's
    /// device resolution so a meeting picks up the same Yeti / AirPods /
    /// whatever the user already chose for dictation.
    ///
    /// `echoCancellation` decides whether macOS's voice-processing chain
    /// (AEC + NS + AGC) runs on the captured audio. See the
    /// `MeetingMicEchoCancellation` enum doc-comment for trade-offs.
    func start(
        at url: URL,
        preferredDevice: AudioDevice?,
        echoCancellation: MeetingMicEchoCancellation = .auto
    ) async throws {
        guard !running else { return }
        self.fileURL = url
        try? FileManager.default.removeItem(at: url)
        didCapture = false
        lastPreferredDevice = preferredDevice
        lastEchoCancellation = echoCancellation

        try configureAndStartEngine(
            preferredDevice: preferredDevice,
            echoCancellation: echoCancellation
        )
        installConfigurationChangeObserver()
        running = true
    }

    /// Stop capture and close the file. Safe to call multiple times.
    func stop() async {
        guard running else { return }
        running = false
        teardownEngine()
        // Drop the file reference last so any in-flight `write` on a
        // concurrently-scheduled main-actor hop finds `running == false`
        // and bails before touching it.
        file = nil
    }

    // MARK: - Engine setup

    /// Build a fresh `AVAudioEngine`, point its input AU at the resolved
    /// device, enable voice processing if requested, install the tap, and
    /// start. Mirrors the dictation recorder's "fresh engine every start"
    /// rule: reusing an engine after a device override leaves the AUHAL
    /// in a stale state where the next tap silently delivers no buffers.
    private func configureAndStartEngine(
        preferredDevice: AudioDevice?,
        echoCancellation: MeetingMicEchoCancellation
    ) throws {
        let newEngine = AVAudioEngine()
        engine = newEngine

        // Resolve the user's input choice to a CoreAudio device ID and
        // pin the input AU to it. AVAudioEngine has no high-level API
        // for this — we reach through to the underlying AUHAL via
        // `audioUnit` and set `kAudioOutputUnitProperty_CurrentDevice`.
        // Failures here are non-fatal: the engine still starts against
        // whatever the system default input is, which is what the user
        // wanted in the "preferredDevice == nil / system default
        // sentinel" case anyway.
        if let coreAudioID = resolveDeviceID(for: preferredDevice),
           let inputAU = newEngine.inputNode.audioUnit {
            var deviceID = coreAudioID
            let status = AudioUnitSetProperty(
                inputAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                NSLog("[Dictator] MeetingMicRecorder couldn't pin input device (status=\(status)); falling back to system default.")
            }
        }

        // Decide AEC. Resolving .auto needs the active output device —
        // do it AFTER the device override above so the heuristic sees the
        // user's actual routing.
        let wantsVoiceProcessing = Self.shouldEnableVoiceProcessing(for: echoCancellation)

        // Voice processing must be toggled BEFORE the engine starts. On
        // macOS the call wires up the playback-reference tap inside
        // AUHAL; flipping it after start does nothing.
        do {
            try newEngine.inputNode.setVoiceProcessingEnabled(wantsVoiceProcessing)
            voiceProcessingActive = wantsVoiceProcessing
        } catch {
            // Voice processing failed to attach (very rare — bad output
            // device, missing entitlement on sandboxed targets). Log and
            // continue without it: a meeting recorded WITHOUT AEC is
            // worse than no meeting at all, and the post-pass dedup will
            // still catch the bleed.
            NSLog("[Dictator] MeetingMicRecorder voice-processing toggle failed (\(error)); recording without AEC.")
            voiceProcessingActive = false
        }

        // `format: nil` is load-bearing. `outputFormat(forBus:)` returns
        // a stale format right after the device override above because
        // the audio unit hasn't propagated the new device yet. Passing
        // nil lets AVAudioEngine pull the actual current format at tap
        // time. Caching the format produces `Failed to create tap due
        // to format mismatch` on the next start.
        //
        // The closure has to be `@Sendable` — installTap dispatches it
        // on the realtime audio queue, which without the annotation
        // would inherit @MainActor isolation from this method and trap
        // the moment the audio thread fires it.
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [weak self] buffer, _ in
            guard let processed = Self.processBuffer(buffer) else { return }
            Task { @MainActor [weak self, processed] in
                guard let self, self.running else { return }
                self.write(
                    samples: processed.mono,
                    sampleRate: processed.sampleRate,
                    level: processed.level
                )
            }
        }

        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            // Surface as a thrown error so the caller's catch in
            // MeetingSession.startRecording can log + fall through (mic
            // failure is non-fatal for the meeting: the system track
            // alone is still useful).
            newEngine.inputNode.removeTap(onBus: 0)
            engine = nil
            voiceProcessingActive = false
            throw error
        }
    }

    /// Tear down the engine cleanly. Safe to call when no engine is live.
    private func teardownEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Mid-recording device-change handler. AirPods connect / USB mic
    /// gets unplugged / a USB hub power-cycles → `AVAudioEngineConfigurationChange`
    /// fires. The handler discards the engine and rebuilds against
    /// whatever the active input is now — same approach the dictation
    /// path's predecessors used. Buffers captured before the swap stay
    /// on disk; we only lose whatever was mid-flight when the
    /// notification fired.
    private func installConfigurationChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleConfigurationChange()
            }
        }
    }

    private func handleConfigurationChange() {
        guard running else { return }
        // Drop the file reference so the next first-buffer write opens
        // a fresh AVAudioFile at the new device's sample rate. Without
        // this, the second engine's buffers would hit an AVAudioFile
        // opened at the old rate and AVAudioFile.write would either
        // throw or silently resample, neither of which is what we want
        // for a crash-safe CAF.
        //
        // Actually — the existing file on disk is intentionally kept.
        // We can't reopen-for-append at a different sample rate without
        // rewriting the header, and starting a new file mid-meeting
        // would split the recording. Pragmatic compromise: keep writing
        // to the original file IFF the rates match, otherwise drop the
        // post-swap audio. This is the same trade-off the dictation
        // path made by discarding the buffer on a configuration change.
        let previousFile = file
        let previousURL = fileURL
        teardownEngine()
        do {
            try configureAndStartEngine(
                preferredDevice: lastPreferredDevice,
                echoCancellation: lastEchoCancellation
            )
            // Reopen on first new-buffer write — `write` already does
            // that when `file == nil`, so just clear the pointer.
            file = previousFile
            _ = previousURL
            installConfigurationChangeObserver()
        } catch {
            NSLog("[Dictator] MeetingMicRecorder lost capture during device switch: \(error)")
            running = false
        }
    }

    // MARK: - File writing

    @MainActor
    private func write(samples: [Float], sampleRate: Double, level: Float) {
        guard running, let url = fileURL else { return }
        do {
            if file == nil {
                file = try Self.openFile(at: url, sampleRate: sampleRate)
            }
            guard let file else { return }
            // Mid-recording device swap may bring back a different
            // native rate. AVAudioFile won't accept a buffer whose rate
            // disagrees with how it was opened; rather than corrupt the
            // CAF, drop the buffer and keep the existing recording.
            guard abs(file.fileFormat.sampleRate - sampleRate) < 1 else {
                onLevel?(level)
                return
            }
            guard let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let dst = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { src -> Void in
                    memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
                }
            }
            try file.write(from: buffer)
            didCapture = true
        } catch {
            NSLog("[Dictator] MeetingMicRecorder write failed: \(error)")
        }
        onLevel?(level)
    }

    private static func openFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    // MARK: - Device + AEC resolution

    /// Resolve a saved preference to a live CoreAudio device ID. nil =
    /// "let the engine use whatever the system default input is", which
    /// is what we want when the user picked the "System default" sentinel
    /// or has nothing saved.
    private nonisolated func resolveDeviceID(for preferred: AudioDevice?) -> AudioDeviceID? {
        guard let preferred, !preferred.isSystemDefault else { return nil }
        return AudioDeviceEnumerator.deviceID(forUID: preferred.uid)
    }

    /// Decide whether voice processing should be enabled for this start.
    /// `.alwaysOn` / `.alwaysOff` short-circuit; `.auto` consults the
    /// current active output device's transport / name via
    /// `outputLooksLikeHeadphones`.
    private nonisolated static func shouldEnableVoiceProcessing(
        for mode: MeetingMicEchoCancellation
    ) -> Bool {
        switch mode {
        case .alwaysOn: return true
        case .alwaysOff: return false
        case .auto:
            guard let outputID = AudioDeviceEnumerator.systemDefaultOutputDeviceID() else {
                // No active output device — laptop muted with no
                // headphones plugged in. AEC is harmless in that case;
                // turn it on so the user isn't surprised when they
                // un-mute mid-meeting.
                return true
            }
            // Headphones → AEC OFF (no bleed). Speakers / ambiguous →
            // AEC ON (bleed risk + the conservative default for the
            // common video-call case).
            //
            // Wait — `outputLooksLikeHeadphones` returns true for
            // ambiguous outputs (external USB interface, HDMI, AirPlay)
            // on the principle "err toward AEC off". So the mapping is
            // simply: headphones-ish → off, speakers → on.
            return !AudioDeviceEnumerator.outputLooksLikeHeadphones(deviceID: outputID)
        }
    }

    // MARK: - Buffer ingest

    private struct Processed {
        let mono: [Float]
        let sampleRate: Double
        let level: Float
    }

    /// Convert an `AVAudioPCMBuffer` from the tap into mono Float32 plus
    /// an RMS level. Mirrors the iOS recorder's shape — much simpler
    /// than the CMBlockBuffer wrangling the dictation `AudioRecorder`
    /// has to do for AVCaptureSession.
    private nonisolated static func processBuffer(_ buffer: AVAudioPCMBuffer) -> Processed? {
        guard let floatData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard channels > 0, sampleRate > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            let src = floatData[0]
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                memcpy(dst.baseAddress!, src, frameCount * MemoryLayout<Float>.size)
            }
        } else {
            mono.withUnsafeMutableBufferPointer { dst -> Void in
                let base = dst.baseAddress!
                let invChannels = 1 / Float(channels)
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channels { sum += floatData[c][i] }
                    base[i] = sum * invChannels
                }
            }
        }

        var rms: Float = 0
        mono.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(mono.count))
        }
        // Same square-root mapping as the dictation recorder — linear
        // scaling collapses quieter mics below the meter floor.
        let level = min(1, max(0, sqrtf(rms) * 2.5))
        return Processed(mono: mono, sampleRate: sampleRate, level: level)
    }
}
