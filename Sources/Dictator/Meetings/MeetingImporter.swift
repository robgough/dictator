import Foundation
@preconcurrency import AVFoundation

/// Copies an imported audio file into a fresh meeting folder, re-encodes
/// it as `system.m4a`, and produces a session pinned to it. The processor
/// path is identical to a live recording with the mic track missing.
@MainActor
enum MeetingImporter {
    /// Build a session from a source audio file the user picked. The
    /// session lands in `.captured` so the caller can immediately run the
    /// processor. The source file is copied (not moved) so the user's
    /// original isn't touched.
    static func makeSession(from source: URL) throws -> MeetingSession {
        let id = UUID()
        let folder = MeetingStorage.folder(for: id)

        // Re-encode to a deterministic system.m4a. AVAudioFile reads any
        // container CoreAudio supports (.m4a, .wav, .mp3, .aac, .flac,
        // .caf) and re-writing to AAC keeps storage uniform.
        let input = try AVAudioFile(forReading: source)
        let processingFormat = input.processingFormat
        let outputURL = MeetingStorage.systemURL(for: id)
        try? FileManager.default.removeItem(at: outputURL)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: processingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // Stream in chunks so we don't allocate a buffer for the entire
        // file at once — long voice-memo imports could be hours.
        let chunkFrames: AVAudioFrameCount = 16_384
        var remaining = AVAudioFrameCount(input.length)
        while remaining > 0 {
            let toRead = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: toRead) else { break }
            try input.read(into: buffer, frameCount: toRead)
            if buffer.frameLength == 0 { break }
            if processingFormat.channelCount > 1 {
                try output.write(from: downmixToMono(buffer, sourceFormat: processingFormat))
            } else {
                try output.write(from: buffer)
            }
            remaining = remaining > buffer.frameLength ? remaining - buffer.frameLength : 0
        }

        let createdAt = Date()
        let title = source.deletingPathExtension().lastPathComponent
        let meta = MeetingMeta(
            id: id,
            title: title.isEmpty ? "Imported audio" : title,
            createdAt: createdAt,
            durationSeconds: Double(input.length) / processingFormat.sampleRate,
            source: .fileImport,
            sourceFilename: source.lastPathComponent,
            audioFiles: .init(mic: nil, system: MeetingStorage.systemFilename),
            speakers: MeetingMeta.defaultImportSpeakers
        )
        try MeetingStorage.writeMeta(meta)
        _ = folder // folder created by MeetingStorage on first touch
        MeetingsStore.shared.upsert(meta)

        let session = MeetingSession(from: meta)
        return session
    }

    private static func downmixToMono(_ buffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else {
            throw NSError(domain: "Dictator.Meetings", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't allocate mono output buffer."])
        }
        mono.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = mono.floatChannelData?[0] {
            let invChannels = 1 / Float(channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][f] }
                dst[f] = sum * invChannels
            }
        }
        return mono
    }
}
