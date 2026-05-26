import Foundation
@preconcurrency import AVFoundation

/// Post-capture (or post-import) pipeline. Reads `mic.m4a` / `system.m4a`
/// off disk, transcribes each track via Parakeet, and writes a single
/// chronological `transcript.json`.
///
/// v0.1 doesn't diarize: the mic track is labelled "me" wholesale and the
/// system track is labelled "other" wholesale. Each track produces a
/// single segment spanning `0…duration`. v0.2 will replace this with the
/// word-level diarization path described in `docs/plans/meetings.md`.
@MainActor
final class MeetingProcessor {
    /// Per-stage progress callback. The caller maps the stage onto a
    /// MeetingSession state.
    enum Stage: Equatable, Sendable {
        case loadingASR
        case transcribingMic
        case transcribingSystem
        case writingTranscript
    }

    /// Run the pipeline. Updates `meta.json` with the final duration +
    /// speaker list, writes `transcript.json`. Throws on Parakeet load /
    /// ASR failure; the caller decides whether to surface that or retry.
    func run(
        session: MeetingSession,
        parakeetModelID: String,
        onProgress: @escaping @MainActor (Stage, Double) -> Void
    ) async throws {
        onProgress(.loadingASR, 0)
        let parakeet = ParakeetServiceHolder.shared
        try await parakeet.ensureLoaded(modelID: parakeetModelID)
        onProgress(.loadingASR, 1)

        var segments: [MeetingTranscriptSegment] = []
        var durationSeconds: Double = 0

        if let micURL = session.micFileURL {
            onProgress(.transcribingMic, 0)
            let (text, duration) = try await transcribe(url: micURL, modelID: parakeetModelID)
            onProgress(.transcribingMic, 1)
            durationSeconds = max(durationSeconds, duration)
            if !text.isEmpty {
                segments.append(MeetingTranscriptSegment(start: 0, end: duration, speakerId: "me", text: text))
            }
        }

        if let systemURL = session.systemFileURL {
            onProgress(.transcribingSystem, 0)
            let (text, duration) = try await transcribe(url: systemURL, modelID: parakeetModelID)
            onProgress(.transcribingSystem, 1)
            durationSeconds = max(durationSeconds, duration)
            if !text.isEmpty {
                segments.append(MeetingTranscriptSegment(start: 0, end: duration, speakerId: "other", text: text))
            }
        }

        onProgress(.writingTranscript, 0)
        let transcript = MeetingTranscript(segments: segments)
        try MeetingStorage.writeTranscript(transcript, for: session.id)

        var meta = session.meta
        meta.durationSeconds = durationSeconds
        try MeetingStorage.writeMeta(meta)
        session.meta = meta
        onProgress(.writingTranscript, 1)
    }

    /// Decode `url` (any format AVAudioFile reads), downmix to mono,
    /// resample to 16 kHz, and feed Parakeet. Returns the raw text plus
    /// the decoded duration (used to fill `MeetingMeta.durationSeconds`).
    private func transcribe(url: URL, modelID: String) async throws -> (String, Double) {
        let samples = try Self.loadMono16k(from: url)
        let durationSeconds = Double(samples.count) / 16_000
        guard !samples.isEmpty else { return ("", durationSeconds) }
        let text = try await ParakeetServiceHolder.shared.transcribe(samples: samples, modelID: modelID)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), durationSeconds)
    }

    /// Read an audio file, downmix to mono Float32, resample to 16 kHz.
    /// Reads in one shot — fine for meeting-length recordings (an hour of
    /// 16 kHz mono Float32 is ~230 MB, comfortably below the headroom we
    /// have on Apple Silicon).
    private nonisolated static func loadMono16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let processingFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return [] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: totalFrames) else {
            return []
        }
        try file.read(into: buffer)
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return [] }

        // Downmix to mono.
        var mono = [Float](repeating: 0, count: frames)
        let channels = Int(processingFormat.channelCount)
        if let data = buffer.floatChannelData {
            if channels == 1 {
                mono.withUnsafeMutableBufferPointer { dst -> Void in
                    memcpy(dst.baseAddress!, data[0], frames * MemoryLayout<Float>.size)
                }
            } else {
                let invChannels = 1 / Float(channels)
                for c in 0..<channels {
                    let src = data[c]
                    for f in 0..<frames {
                        mono[f] += src[f]
                    }
                }
                for f in 0..<frames { mono[f] *= invChannels }
            }
        }

        let sourceRate = processingFormat.sampleRate
        if abs(sourceRate - 16_000) < 1 { return mono }
        return AudioResampler.mono(samples: mono, from: sourceRate, to: 16_000) ?? mono
    }
}
