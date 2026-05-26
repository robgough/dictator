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
