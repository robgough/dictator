import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// Copies an imported audio file into a fresh meeting folder, re-encodes
/// it as `system.m4a`, and produces a session pinned to it. The processor
/// path is identical to a live recording with the mic track missing.
@MainActor
enum MeetingImporter {
    /// Audio file types accepted by both the Import… NSOpenPanel and the
    /// drag-and-drop zones (menu bar + Meetings window). Kept central so
    /// the two entry points stay in sync. `nonisolated` so the menu bar's
    /// non-actor-isolated drop callbacks (which fire on arbitrary queues)
    /// can read it without an actor hop.
    nonisolated static let acceptedContentTypes: [UTType] = [
        UTType.audio,
        UTType(filenameExtension: "m4a") ?? .audio,
        UTType(filenameExtension: "wav") ?? .audio,
        UTType(filenameExtension: "mp3") ?? .audio,
        UTType(filenameExtension: "aac") ?? .audio,
        UTType(filenameExtension: "flac") ?? .audio,
        UTType(filenameExtension: "caf") ?? .audio,
    ]

    /// Lowercased file extensions matching `acceptedContentTypes`. Used by
    /// the drop-zone path to filter URLs the OS hands us — `UTType.audio`
    /// covers most cases via UTI conformance, but a few file types (e.g.
    /// raw `.flac` on older systems) lack the right conformance tree, and
    /// `NSItemProvider` doesn't always vend a usable conformance for
    /// file-promise drops. Falling back to extension matching keeps the
    /// drop affordance permissive.
    nonisolated static let acceptedExtensions: Set<String> = [
        "m4a", "wav", "mp3", "aac", "flac", "caf", "mp4", "mov", "aiff", "aif",
    ]

    /// True when the URL's extension or UTI conformance suggests an audio
    /// file. Used by the drop-zone path — we accept on either signal so a
    /// well-known extension lands even when the UTI db doesn't know about
    /// the type, and a custom-extension audio file still works as long as
    /// its UTI conforms to `public.audio`.
    nonisolated static func urlLooksLikeAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if acceptedExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) { return true }
        return false
    }
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
