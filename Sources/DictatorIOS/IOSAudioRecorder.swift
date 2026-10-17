import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// iOS microphone capture. Stripped-down counterpart to the macOS
/// `AudioRecorder`:
/// - No user-pickable device. iOS handles routing automatically (built-in
///   mic, AirPods if connected, USB-C / Lightning headset if plugged in).
/// - No Bluetooth warmup gymnastics, silent-capture watchdog, or
///   same-device retry policy. Those exist on macOS to paper over
///   CoreAudio HAL flakiness with USB devices; iOS doesn't have that
///   problem class.
/// - `AVAudioEngine` + `installTap` instead of `AVCaptureSession`. On
///   macOS we switched away from the engine because it didn't cope
///   gracefully with mid-session device swaps; iOS doesn't expose those
///   swaps the same way and the engine is the idiomatic path.
///
/// Output: 16 kHz mono Float32, the format Parakeet expects.
@MainActor
final class IOSAudioRecorder {
    private let targetSampleRate: Double = 16_000
    private var rawBuffer: [Float] = []
    private var nativeSampleRate: Double = 0
    /// True while samples are being kept — between `start()` and `stop()`.
    private var capturing = false

    /// The engine, alive from the first `start()` until `shutdown()` (or
    /// until `stop()` when `keepWarm` is false). Fresh per arming — see
    /// `armEngine()` for why.
    private var engine: AVAudioEngine?

    /// When true, `stop()` closes the capture gate but leaves the engine and
    /// audio session running, so the next `start()` is instant and — the
    /// point of it — can happen while Dictator is in the background, where
    /// iOS refuses to *activate* a recording session. Set by the background
    /// session (`BackgroundSession`); the mic indicator stays lit for as long
    /// as the engine runs, which is the honest cost of it.
    var keepWarm = false

    /// True while the engine is running, whether or not samples are kept.
    var isArmed: Bool { engine != nil }

    /// 0...1 RMS reported on the main actor, only while capturing.
    var onLevel: (@MainActor (Float) -> Void)?

    /// Fired once capture is live.
    var onReady: (@MainActor () -> Void)?

    /// Fired if session setup or `engine.start()` throws. Recorder is
    /// left in a stopped state with the audio session deactivated.
    var onStartFailed: (@MainActor (Error) -> Void)?

    /// Fired when the system takes the mic away (a phone call, Siri, the
    /// media server resetting) or a route change kills an engine we can't
    /// rebuild. Samples captured so far are still returned by `stop()`, so
    /// the owner can finish the recording rather than lose it.
    var onInterrupted: (@MainActor () -> Void)?

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.handleLostEngine() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleLostEngine() }
        })
    }

    /// Ask the user for microphone permission. Idempotent — if the user
    /// has already granted (or denied) it returns the cached decision
    /// without showing the prompt again. Call this before `start()`.
    static func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Current permission state without prompting. Useful for deciding
    /// whether to show a "grant microphone access" UI before calling
    /// `requestRecordPermission()`.
    static var recordPermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Begin keeping samples. Arms the engine first if it isn't running —
    /// which only succeeds in the foreground; a warm engine makes this work
    /// from the background too.
    func start() {
        guard !capturing else { return }
        if engine == nil {
            do {
                try armEngine()
            } catch {
                onStartFailed?(error)
                return
            }
        }
        rawBuffer.removeAll(keepingCapacity: true)
        nativeSampleRate = 0
        capturing = true
        onReady?()
    }

    /// Stop keeping samples and return them as 16 kHz mono Float32. Tears
    /// the engine down unless `keepWarm` is set. Safe to call repeatedly;
    /// later calls return [].
    func stop() -> [Float] {
        guard capturing else {
            if !keepWarm { shutdown() }
            return []
        }
        capturing = false
        if !keepWarm { shutdown() }

        let samples = rawBuffer
        let rate = nativeSampleRate
        rawBuffer.removeAll(keepingCapacity: false)

        guard rate > 0 else { return samples }
        return Self.resample(monoSamples: samples, fromSampleRate: rate, toSampleRate: targetSampleRate)
            ?? samples
    }

    /// Stop the engine and release the mic (the indicator goes out). Any
    /// capture in progress is discarded — call `stop()` first to keep it.
    func shutdown() {
        capturing = false
        guard let engine else { return }
        self.engine = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private var configObserver: NSObjectProtocol?

    private func armEngine() throws {
        let session = AVAudioSession.sharedInstance()
        if keepWarm {
            // A warm session can sit open for many minutes while the user
            // is listening to something else, so it must not duck or stop
            // other audio: `.playAndRecord` is the only recording category
            // that accepts `.mixWithOthers`. `.measurement` still bypasses
            // the voice-processing chain, which Parakeet transcribes worse.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
            )
        } else {
            // `.measurement` mode disables iOS's voice-processing chain
            // (echo cancellation, AGC). Parakeet was trained on un-processed
            // audio; running through the voice chain colours the spectrum
            // and noticeably hurts WER. `.allowBluetoothHFP` lets AirPods /
            // BT headsets act as the input. `.duckOthers` quiets music
            // playback while recording rather than stopping it outright.
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP, .duckOthers])
        }
        try session.setActive(true)

        // Fresh AVAudioEngine on every arming. Reusing the same instance
        // across teardown → start cycles leaves the input node's
        // tap-format and AUHAL state stale — on the second recording the
        // tap silently delivers no buffers (which is exactly the "ring
        // doesn't move on the second go" symptom). The macOS recorder
        // hit the same problem with AVCaptureSession reuse after a
        // device override; recreating is cheap and avoids a whole
        // category of bugs.
        let newEngine = AVAudioEngine()

        // `format: nil` lets the engine pull whatever format the input
        // node is actually running at. Hardcoding a format and then
        // hitting a sample-rate mismatch silently drops the tap.
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [weak self] buffer, _ in
            guard let processed = Self.processBuffer(buffer) else { return }
            Task { @MainActor [weak self, processed] in
                guard let self, self.capturing else { return }
                self.appendSamples(
                    mono: processed.mono,
                    level: processed.level,
                    sampleRate: processed.sampleRate
                )
            }
        }

        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            newEngine.inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }
        engine = newEngine
        // A route change (AirPods connecting, a headset unplugged) stops the
        // engine. Rebuild in place so a warm session survives it; the audio
        // session stays active throughout, so this works in the background.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAfterConfigurationChange() }
        }
    }

    private func rebuildAfterConfigurationChange() {
        guard let old = engine else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        old.inputNode.removeTap(onBus: 0)
        old.stop()
        engine = nil
        do {
            try armEngine()
        } catch {
            NSLog("[DictatorIOS] Engine rebuild after route change failed: \(error.localizedDescription)")
            onInterrupted?()
        }
    }

    /// The mic is gone. Keep whatever was captured for `stop()` to return,
    /// drop the engine, and tell the owner.
    private func handleLostEngine() {
        guard let engine else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        onInterrupted?()
    }

    private func appendSamples(mono: [Float], level: Float, sampleRate: Double) {
        guard capturing else { return }
        rawBuffer.append(contentsOf: mono)
        nativeSampleRate = sampleRate
        onLevel?(level)
    }

    // MARK: - Static helpers (nonisolated; run on the audio-render thread)

    private struct ProcessedBuffer: Sendable {
        let mono: [Float]
        let level: Float
        let sampleRate: Double
    }

    /// Extract a mono Float32 array + RMS level from an AVAudioPCMBuffer.
    /// `floatChannelData` exposes per-channel float pointers directly —
    /// the AVAudioEngine path is much friendlier than CMBlockBuffer-
    /// wrangling on the AVCaptureSession side.
    private nonisolated static func processBuffer(_ buffer: AVAudioPCMBuffer) -> ProcessedBuffer? {
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
        mono.withUnsafeBufferPointer { ptr -> Void in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(frameCount))
        }
        // Same square-root mapping as the macOS recorder — linear scaling
        // collapses quieter mics below the level meter's floor.
        let level = min(1, max(0, sqrtf(rms) * 2.5))
        return ProcessedBuffer(mono: mono, level: level, sampleRate: sampleRate)
    }

    private nonisolated static func resample(
        monoSamples: [Float],
        fromSampleRate: Double,
        toSampleRate: Double
    ) -> [Float]? {
        guard !monoSamples.isEmpty else { return [] }
        if abs(fromSampleRate - toSampleRate) < 1 { return monoSamples }

        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromSampleRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: toSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(monoSamples.count))
        else { return nil }

        inputBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            monoSamples.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, monoSamples.count * MemoryLayout<Float>.size)
            }
        }

        let ratio = toSampleRate / fromSampleRate
        let outCap = AVAudioFrameCount(Double(monoSamples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return nil }

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

private final class MutableFlag: @unchecked Sendable {
    var value: Bool = false
}
