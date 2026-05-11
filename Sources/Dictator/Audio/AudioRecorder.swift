import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreAudio

private final class MutableFlag: @unchecked Sendable {
    var value: Bool = false
}

@MainActor
final class AudioRecorder {
    // Recreated on every `start()`. Reusing the same instance after a device
    // override on macOS can leave the AUHAL in a state where `start()` returns
    // -10868 (kAudioUnitErr_FormatNotSupported). A fresh engine is the cleanest
    // workaround.
    private var engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var rawBuffer: [Float] = []        // mono, at native sample rate
    private var nativeSampleRate: Double = 0   // populated from the first tap buffer
    private var running = false
    private var configChangeObserver: NSObjectProtocol?

    /// 0...1 RMS reported on the main actor.
    var onLevel: (@MainActor (Float) -> Void)?

    /// Called if the audio engine configuration changes while recording (e.g. the
    /// chosen input device was disconnected). The recorder stops itself first.
    var onUnexpectedStop: (@MainActor (String) -> Void)?

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }

    func start() throws {
        guard !running else { return }
        rawBuffer.removeAll(keepingCapacity: true)

        let preferred = AudioDeviceManager.shared.activeInputDeviceID()
        do {
            try configureAndStartEngine(deviceOverride: preferred)
        } catch {
            // Fall back to system default if a device override caused
            // engine.start() to fail (commonly with -10868 on rate-mismatched
            // devices). Recreate the engine cleanly and try once more.
            engine = AVAudioEngine()
            try configureAndStartEngine(deviceOverride: nil)
        }
    }

    private func configureAndStartEngine(deviceOverride: AudioDeviceID?) throws {
        // Fresh engine each call so the AUHAL has no stale device/format state.
        engine = AVAudioEngine()

        if let id = deviceOverride {
            try? Self.setInputDevice(id, on: engine)
        }

        let input = engine.inputNode
        nativeSampleRate = 0

        input.removeTap(onBus: 0)
        // The @Sendable annotation is critical: without it, this closure inherits
        // @MainActor isolation from the enclosing method, and Swift inserts an
        // isolation check at its entry. When AVAudioEngine then invokes the closure
        // on its realtime audio thread, the check fails and dispatch traps the process.
        //
        // We pass `format: nil` so AVAudioEngine uses the input node's *actual*
        // current format. Querying `outputFormat(forBus:)` right after
        // `setInputDevice` can return a stale format (the audio unit hasn't yet
        // propagated the switch), and installing the tap with that mismatched
        // format makes AVFAudio throw "Failed to create tap due to format mismatch".
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] pcm, _ in
            let rate = pcm.format.sampleRate
            guard let (mono, level) = Self.monoMixWithLevel(pcm: pcm) else { return }
            Task { @MainActor [weak self, mono, level, rate] in
                self?.rawBuffer.append(contentsOf: mono)
                self?.nativeSampleRate = rate
                self?.onLevel?(level)
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)

        // Listen for device-change-mid-flight events. AVAudioEngine pauses on its
        // own; we tell the caller so the recording can be ended cleanly. The
        // observer is removed *inside* the handler before we forward upstream,
        // otherwise a follow-up notification can re-enter the handler and trip
        // through to fail() again while we're already cleaning up.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    /// Remove the configuration-change observer and clear our tap so that any
    /// queued duplicate notification is a no-op.
    private func tearDownObservers() {
        engine.inputNode.removeTap(onBus: 0)
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
    }

    private func handleConfigurationChange() {
        guard running else { return }
        // Tear down before re-configuring so any follow-up notification while
        // we're swapping is a no-op.
        tearDownObservers()
        engine.stop()
        running = false

        // The macOS audio path fires this notification whenever the active
        // input changes (USB / Bluetooth mic unplugged, AirPods connect, hub
        // power cycle, …). The previous behaviour treated it as a hard
        // failure and dumped the user back to the HUD with an error. The
        // kinder UX is to silently restart on whatever input is active now
        // so they can keep dictating uninterrupted.
        //
        // Any audio captured before the swap is discarded — the old and new
        // devices typically sample at different rates and our buffer assumes
        // a single native rate per recording. In practice the swap usually
        // happens at the very start of a recording anyway (e.g. AUHAL
        // discovers the saved preferred device is gone and falls back), so
        // there's nothing meaningful to keep.
        rawBuffer.removeAll(keepingCapacity: true)
        nativeSampleRate = 0

        do {
            try configureAndStartEngine(deviceOverride: nil)
        } catch {
            // Couldn't restart — typically means there's no usable input
            // device at all. Now we surface the failure upstream so the
            // pipeline can end the recording cleanly rather than hanging on
            // a silent recorder.
            let device = AudioDeviceManager.shared.activeInputDeviceName()
            onUnexpectedStop?("Audio input changed mid-recording (now: \(device)).")
        }
    }

    private static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Couldn't set input device (OSStatus \(status))"]
            )
        }
    }

    /// Stops recording and returns 16 kHz mono Float32 samples ready for WhisperKit.
    /// All sample-rate conversion happens here on the main actor, off the audio thread.
    func stop() -> [Float] {
        // We can be called from finishRecording() (normal release of hotkey) OR
        // after handleConfigurationChange() has already torn things down. Both
        // paths must end with the buffered samples drained.
        if running {
            tearDownObservers()
            engine.stop()
            running = false
        }

        let nativeSamples = rawBuffer
        let sampleRate = nativeSampleRate
        rawBuffer.removeAll(keepingCapacity: false)

        guard sampleRate > 0,
              let resampled = Self.resampleToTarget(monoSamples: nativeSamples, fromSampleRate: sampleRate, to: targetFormat)
        else { return nativeSamples } // fall back to raw if anything goes wrong

        return resampled
    }

    // MARK: - Audio thread helpers (pure functions, no shared state)

    /// Downmix to mono and return RMS for the meter. Runs on the audio thread, so
    /// it must be `nonisolated` — otherwise the @MainActor class isolation propagates
    /// and Swift's runtime executor check fires when this is invoked off-main.
    private nonisolated static func monoMixWithLevel(pcm: AVAudioPCMBuffer) -> ([Float], Float)? {
        guard let channelData = pcm.floatChannelData else { return nil }
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0 else { return ([], 0) }
        let channels = Int(pcm.format.channelCount)

        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            _ = mono.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, channelData[0], frameCount * MemoryLayout<Float>.size)
            }
        } else {
            // Average all channels.
            _ = mono.withUnsafeMutableBufferPointer { dst in
                let base = dst.baseAddress!
                for i in 0..<frameCount { base[i] = 0 }
                for ch in 0..<channels {
                    vDSP_vadd(base, 1, channelData[ch], 1, base, 1, vDSP_Length(frameCount))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frameCount))
            }
        }

        var rms: Float = 0
        _ = mono.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(frameCount))
        }
        let level = min(1, max(0, rms * 8))
        return (mono, level)
    }

    // MARK: - Main thread resample
    private nonisolated static func resampleToTarget(monoSamples: [Float], fromSampleRate: Double, to target: AVAudioFormat) -> [Float]? {
        guard !monoSamples.isEmpty else { return [] }
        if abs(fromSampleRate - target.sampleRate) < 1 { return monoSamples }

        // Build a transient AVAudioConverter; created and used entirely on main.
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: target),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(monoSamples.count))
        else { return nil }

        inputBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            monoSamples.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, monoSamples.count * MemoryLayout<Float>.size)
            }
        }

        let ratio = target.sampleRate / fromSampleRate
        let outCap = AVAudioFrameCount(Double(monoSamples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return nil }

        var error: NSError?
        let supplied = MutableFlag()
        converter.convert(to: outBuffer, error: &error) { _, status in
            if supplied.value {
                status.pointee = .endOfStream
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return inputBuffer
        }
        if error != nil { return nil }
        guard let outData = outBuffer.floatChannelData?[0] else { return nil }
        let outCount = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outData, count: outCount))
    }
}
