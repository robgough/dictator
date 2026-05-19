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

    /// Generation counter so that a Bluetooth start still in HFP negotiation
    /// when the user releases the hotkey doesn't end up adopting its engine
    /// after we've already returned to .idle. Bumped by `start`, `stop`, and
    /// `cancelStart`.
    private var startGeneration: Int = 0
    /// True between `start()` returning and the engine actually producing
    /// audio. Caller checks via `onReady`; we use it internally to dedupe
    /// overlapping starts.
    private var startInFlight: Bool = false

    /// 0...1 RMS reported on the main actor.
    var onLevel: (@MainActor (Float) -> Void)?

    /// Called once the engine is genuinely running and the tap is installed.
    /// On Bluetooth mics this can fire 2–5 s after `start()` returns —
    /// callers should reflect a "warming up" state in their UI until this
    /// fires.
    var onReady: (@MainActor () -> Void)?

    /// Called if engine startup fails outright (mic permission denied at
    /// driver level, no input device available, etc.). The recorder is left
    /// in a stopped state; caller should surface the error and reset.
    var onStartFailed: (@MainActor (Error) -> Void)?

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

    /// Kick off engine startup. Returns immediately — actual engine setup
    /// runs off-main because two of its steps (`setInputDevice` and
    /// `engine.start()`) can block for seconds on Bluetooth mics while
    /// macOS negotiates the HFP profile. The caller is notified of
    /// completion via `onReady` (success) or `onStartFailed` (failure),
    /// both fired on the main actor.
    ///
    /// Previously this method was throwing-synchronous, which beach-balled
    /// the main thread (and the HUD) on every dictation press whenever the
    /// active input was a BT device.
    func start() {
        guard !running, !startInFlight else { return }
        rawBuffer.removeAll(keepingCapacity: true)

        startInFlight = true
        startGeneration &+= 1
        startEngineAsync(
            deviceOverride: AudioDeviceManager.shared.activeInputDeviceID(),
            allowDefaultFallback: true,
            generation: startGeneration,
            timeoutSeconds: 10
        )
    }

    /// Abort an in-flight startup. The async setup task still runs to
    /// completion (we can't preempt CoreAudio profile negotiation), but its
    /// completion handler discards the engine instead of adopting it. Safe
    /// to call when no startup is in flight.
    func cancelStart() {
        startGeneration &+= 1
        startInFlight = false
    }

    private func startEngineAsync(
        deviceOverride: AudioDeviceID?,
        allowDefaultFallback: Bool,
        generation: Int,
        timeoutSeconds: Double
    ) {
        // The tap closure is constructed on main but invoked on the
        // realtime audio thread, hence @Sendable. format: nil is also
        // load-bearing — see the long comment in the original sync impl.
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] pcm, _ in
            let rate = pcm.format.sampleRate
            guard let (mono, level) = Self.monoMixWithLevel(pcm: pcm) else { return }
            Task { @MainActor [weak self, mono, level, rate] in
                self?.rawBuffer.append(contentsOf: mono)
                self?.nativeSampleRate = rate
                self?.onLevel?(level)
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            let newEngine = AVAudioEngine()
            do {
                if let id = deviceOverride {
                    try? Self.setInputDevice(id, on: newEngine)
                }
                let input = newEngine.inputNode
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: tap)
                newEngine.prepare()
                try newEngine.start()
            } catch {
                await self?.handleStartFailure(
                    error: error,
                    allowDefaultFallback: allowDefaultFallback,
                    generation: generation
                )
                return
            }

            await self?.completeStart(newEngine: newEngine, generation: generation)
        }

        // Warmup watchdog. CoreAudio occasionally blocks indefinitely on USB
        // device negotiation — a Yeti / similar mic claimed exclusively by
        // another app, a device in power-state limbo, or coreaudiod stuck
        // after a recent input swap. Without this we'd sit in .warmingUp
        // forever (engine.start() never returns → completeStart never runs).
        // After timeoutSeconds we treat the in-flight attempt as failed and
        // route through handleStartFailure, which will retry against the
        // system default if allowed, otherwise surface the error.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            guard let self else { return }
            guard self.startInFlight, generation == self.startGeneration else { return }
            let device = AudioDeviceManager.shared.activeInputDeviceName()
            let err = NSError(
                domain: "Dictator",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "\(device) didn't respond. Another app may be using it — try a different input in Settings."
                ]
            )
            self.handleStartFailure(
                error: err,
                allowDefaultFallback: allowDefaultFallback,
                generation: generation
            )
        }
    }

    /// Main-actor completion handler for a successful off-main start.
    private func completeStart(newEngine: AVAudioEngine, generation: Int) {
        guard generation == startGeneration else {
            // User released the hotkey while we were still warming up.
            // Drop this engine — onReady would now be wrong to fire.
            newEngine.stop()
            return
        }
        nativeSampleRate = 0
        engine = newEngine
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleConfigurationChange()
            }
        }
        running = true
        startInFlight = false
        onReady?()
    }

    private func handleStartFailure(
        error: Error,
        allowDefaultFallback: Bool,
        generation: Int
    ) {
        guard generation == startGeneration else { return }
        if allowDefaultFallback {
            // Bump the generation so any still-pending detached task from
            // the failed attempt becomes stale on completion (matters when
            // the watchdog routed us here — the original engine.start() may
            // still be blocked deep in CoreAudio). Then retry against the
            // system default with a tighter watchdog; if that hangs too,
            // there's nothing we can do but tell the user.
            startGeneration &+= 1
            startEngineAsync(
                deviceOverride: nil,
                allowDefaultFallback: false,
                generation: startGeneration,
                timeoutSeconds: 4
            )
        } else {
            startInFlight = false
            onStartFailed?(error)
        }
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
        // power cycle, …). Restart on whatever input is active now so the
        // user can keep dictating uninterrupted.
        //
        // Any audio captured before the swap is discarded — the old and new
        // devices typically sample at different rates and our buffer assumes
        // a single native rate per recording.
        rawBuffer.removeAll(keepingCapacity: true)
        nativeSampleRate = 0

        // Route through the async path. If the swap is to a Bluetooth
        // device the user may see a brief gap while HFP comes up — that's
        // strictly better than beach-balling mid-dictation. If the restart
        // ultimately fails, `onStartFailed` will fire and we forward it as
        // an unexpected stop.
        let priorOnStartFailed = onStartFailed
        onStartFailed = { [weak self] _ in
            guard let self else { return }
            let device = AudioDeviceManager.shared.activeInputDeviceName()
            self.onUnexpectedStop?("Audio input changed mid-recording (now: \(device)).")
            // Restore the original handler so the next user-initiated start
            // surfaces its failure to the pipeline normally.
            self.onStartFailed = priorOnStartFailed
        }
        startInFlight = true
        startGeneration &+= 1
        startEngineAsync(
            deviceOverride: nil,
            allowDefaultFallback: false,
            generation: startGeneration,
            timeoutSeconds: 10
        )
    }

    private nonisolated static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
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
        //
        // Bump the generation so a startup still warming up adopts nothing.
        startGeneration &+= 1
        startInFlight = false
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
