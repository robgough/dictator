import Foundation
@preconcurrency import AVFoundation

private final class MutableFlag: @unchecked Sendable {
    var value: Bool = false
}

/// Mono Float32 sample-rate conversion via AVAudioConverter. Lifted out of
/// `AudioRecorder` so both the dictation path and the meeting processor can
/// share one helper — the latter feeds Parakeet from an arbitrary-rate
/// source file and needs the same 16 kHz landing zone as the live recorder.
enum AudioResampler {
    /// Convert a mono Float32 stream from `from` Hz to `to` Hz. Returns the
    /// input untouched when the rates already match, or `nil` if AV could
    /// not build the converter / buffers.
    static func mono(
        samples: [Float],
        from: Double,
        to: Double
    ) -> [Float]? {
        guard !samples.isEmpty else { return [] }
        if abs(from - to) < 1 { return samples }

        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
            }
        }

        let ratio = to / from
        let outCap = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
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

/// Reusable mono Float32 → 16 kHz (or any target) sample-rate converter.
///
/// Unlike the one-shot `AudioResampler.mono` static helper, this caches the
/// `AVAudioConverter` and its formats and reuses them across calls, rebuilding
/// only when the source rate changes. The live meeting path resamples every
/// ~10 ms audio buffer for the entire call; building a fresh converter (plus
/// two formats and an input buffer) per buffer was hundreds of thousands of
/// allocations over a long meeting, much of it on the main actor — a real
/// driver of the in-call slowdown. `reset()` before each buffer keeps the
/// per-buffer semantics identical to the static helper (each buffer converted
/// as its own short stream), so only the allocation cost is removed.
///
/// NOT thread-safe: confine each instance to a single execution context (the
/// live transcriber keeps one per source — system on the main actor, mic on
/// its capture queue — so they never touch the same instance concurrently).
public final class MonoResampler {
    private let targetRate: Double
    private var targetFormat: AVAudioFormat?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var cachedSourceRate: Double = 0

    public init(targetRate: Double) {
        self.targetRate = targetRate
    }

    /// Convert mono Float32 `samples` from `rate` Hz to the target rate.
    /// Returns the input untouched when the rates already match, or `nil` if
    /// AV couldn't build the converter / buffers.
    public func resample(_ samples: [Float], from rate: Double) -> [Float]? {
        guard !samples.isEmpty else { return [] }
        if abs(rate - targetRate) < 1 { return samples }

        if converter == nil || abs(cachedSourceRate - rate) >= 1 {
            guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let dst = targetFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
                  let conv = AVAudioConverter(from: src, to: dst)
            else { return nil }
            sourceFormat = src
            targetFormat = dst
            converter = conv
            cachedSourceRate = rate
        }
        guard let converter, let sourceFormat, let targetFormat,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = inputBuffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src -> Void in
                memcpy(dst, src.baseAddress!, samples.count * MemoryLayout<Float>.size)
            }
        }

        let ratio = targetRate / rate
        let outCap = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return nil }

        // Reset so the cached converter treats this buffer as its own short
        // stream — identical semantics to building a fresh converter, minus
        // the allocation.
        converter.reset()
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
        return Array(UnsafeBufferPointer(start: outData, count: Int(outBuffer.frameLength)))
    }
}
