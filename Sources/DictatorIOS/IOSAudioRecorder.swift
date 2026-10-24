import Foundation
@preconcurrency import AVFoundation
import Accelerate
import os

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
    /// Where the audio thread puts samples. Never via the main actor: a
    /// per-buffer hop to the main actor queues behind whatever the UI is
    /// drawing, and loses the end of a recording when `stop()` runs ahead
    /// of the hops still waiting.
    private let store = CaptureStore()
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

    /// 0...1 RMS reported on the main actor, only while capturing, at most
    /// about 30 times a second (it only drives meters).
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
        store.open()
        capturing = true
        onReady?()
    }

    /// Stop keeping samples and hand back everything captured, at the
    /// device's rate — `CapturedAudio.resampled()` converts it to 16 kHz off
    /// the main actor. The gate closes and any buffer the audio thread is
    /// part-way through is waited for, so nothing already heard is lost.
    /// Tears the engine down unless `keepWarm` is set. Safe to call
    /// repeatedly; later calls return nothing.
    func stop() -> CapturedAudio {
        guard capturing else {
            if !keepWarm { shutdown() }
            return CapturedAudio(samples: [], sampleRate: 0, targetSampleRate: targetSampleRate)
        }
        capturing = false
        let taken = store.closeAndDrain()
        if !keepWarm { shutdown() }
        return CapturedAudio(samples: taken.samples, sampleRate: taken.sampleRate, targetSampleRate: targetSampleRate)
    }

    /// Stop the engine and release the mic (the indicator goes out). Any
    /// capture in progress is discarded — call `stop()` first to keep it.
    func shutdown() {
        if capturing {
            capturing = false
            _ = store.closeAndDrain()
        }
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
        //
        // The block runs on the engine's tap thread: it appends straight
        // into the lock-protected store and only sends the main actor the
        // level, throttled, for the meters.
        let store = store
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [weak self] buffer, _ in
            guard store.enter() else { return }
            let processed = Self.processBuffer(buffer)
            guard let level = store.finish(processed) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.deliverLevel(level) }
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

    private func deliverLevel(_ level: Float) {
        guard capturing else { return }
        onLevel?(level)
    }

    // MARK: - Static helpers (nonisolated; run on the audio-render thread)

    fileprivate struct ProcessedBuffer: Sendable {
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

    fileprivate nonisolated static func resample(
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

/// What `IOSAudioRecorder.stop()` captured, still at the device's rate.
struct CapturedAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let targetSampleRate: Double

    var isEmpty: Bool { samples.isEmpty }

    /// The samples as 16 kHz mono Float32, the format Parakeet expects.
    /// Converted on a background thread: AVAudioConverter over a long
    /// recording is enough work to drop frames if it runs on the main actor
    /// while the record button is morphing.
    func resampled() async -> [Float] {
        let samples = samples
        let rate = sampleRate
        let target = targetSampleRate
        guard rate > 0, !samples.isEmpty else { return samples }
        return await Task.detached(priority: .userInitiated) {
            IOSAudioRecorder.resample(monoSamples: samples, fromSampleRate: rate, toSampleRate: target) ?? samples
        }.value
    }
}

/// The capture buffer, shared between the tap thread (which appends) and the
/// main actor (which opens, closes and takes it). One unfair lock guards it;
/// every critical section is a few assignments or an append.
private final class CaptureStore: Sendable {
    private struct State: Sendable {
        var capturing = false
        /// Tap callbacks that passed the gate and haven't appended yet.
        var inFlight = 0
        var samples: [Float] = []
        var sampleRate: Double = 0
        var lastLevelPost: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Meters don't need more than this; the main actor shouldn't get more.
    private static let levelInterval: UInt64 = 33_000_000

    func open() {
        state.withLock {
            $0.capturing = true
            $0.samples.removeAll(keepingCapacity: true)
            $0.sampleRate = 0
            $0.lastLevelPost = 0
        }
    }

    /// Tap thread: claim a slot if samples are being kept.
    func enter() -> Bool {
        state.withLock {
            guard $0.capturing else { return false }
            $0.inFlight += 1
            return true
        }
    }

    /// Tap thread: append a claimed buffer (even if the gate closed since —
    /// `closeAndDrain` is waiting for it) and return a level to show, if
    /// one is due.
    func finish(_ processed: IOSAudioRecorder.ProcessedBuffer?) -> Float? {
        let now = DispatchTime.now().uptimeNanoseconds
        return state.withLock {
            $0.inFlight -= 1
            guard let processed else { return nil }
            $0.samples.append(contentsOf: processed.mono)
            $0.sampleRate = processed.sampleRate
            guard $0.capturing, now &- $0.lastLevelPost >= Self.levelInterval else { return nil }
            $0.lastLevelPost = now
            return processed.level
        }
    }

    /// Main actor: stop keeping samples, wait for a callback caught mid-way
    /// (microseconds — it's only converting one buffer), and take the lot.
    func closeAndDrain() -> (samples: [Float], sampleRate: Double) {
        state.withLock { $0.capturing = false }
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        while state.withLock({ $0.inFlight > 0 }), DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(50)
        }
        return state.withLock {
            let taken = ($0.samples, $0.sampleRate)
            $0.samples = []
            $0.sampleRate = 0
            return taken
        }
    }
}
