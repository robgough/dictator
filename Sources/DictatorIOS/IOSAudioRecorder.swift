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
    private var running = false

    /// Fresh per recording — see `start()` for why. Nil between `stop()`
    /// and the next `start()`.
    private var engine: AVAudioEngine?

    /// 0...1 RMS reported on the main actor.
    var onLevel: (@MainActor (Float) -> Void)?

    /// Fired once the engine has started and the audio session is active.
    var onReady: (@MainActor () -> Void)?

    /// Fired if session setup or `engine.start()` throws. Recorder is
    /// left in a stopped state with the audio session deactivated.
    var onStartFailed: (@MainActor (Error) -> Void)?

    init() {}

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

    func start() {
        guard !running else { return }
        rawBuffer.removeAll(keepingCapacity: true)
        nativeSampleRate = 0

        do {
            let session = AVAudioSession.sharedInstance()
            // `.measurement` mode disables iOS's voice-processing chain
            // (echo cancellation, AGC). Parakeet was trained on un-processed
            // audio; running through the voice chain colours the spectrum
            // and noticeably hurts WER. `.allowBluetoothHFP` lets AirPods /
            // BT headsets act as the input. `.duckOthers` quiets music
            // playback while recording rather than stopping it outright.
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP, .duckOthers])
            try session.setActive(true)
        } catch {
            onStartFailed?(error)
            return
        }

        // Fresh AVAudioEngine on every start. Reusing the same instance
        // across `stop()` → `start()` cycles leaves the input node's
        // tap-format and AUHAL state stale — on the second recording the
        // tap silently delivers no buffers (which is exactly the "ring
        // doesn't move on the second go" symptom). The macOS recorder
        // hit the same problem with AVCaptureSession reuse after a
        // device override; recreating is cheap and avoids a whole
        // category of bugs.
        let newEngine = AVAudioEngine()
        engine = newEngine

        // `format: nil` lets the engine pull whatever format the input
        // node is actually running at. Hardcoding a format and then
        // hitting a sample-rate mismatch silently drops the tap.
        newEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable [weak self] buffer, _ in
            guard let processed = Self.processBuffer(buffer) else { return }
            Task { @MainActor [weak self, processed] in
                guard let self, self.running else { return }
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
            running = true
            onReady?()
        } catch {
            newEngine.inputNode.removeTap(onBus: 0)
            engine = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            onStartFailed?(error)
        }
    }

    /// Stop capture, deactivate the audio session, and return 16 kHz mono
    /// Float32 samples. Safe to call repeatedly; later calls return [].
    func stop() -> [Float] {
        guard running else { return [] }
        running = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        let samples = rawBuffer
        let rate = nativeSampleRate
        rawBuffer.removeAll(keepingCapacity: false)

        guard rate > 0 else { return samples }
        return Self.resample(monoSamples: samples, fromSampleRate: rate, toSampleRate: targetSampleRate)
            ?? samples
    }

    private func appendSamples(mono: [Float], level: Float, sampleRate: Double) {
        guard running else { return }
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
