import Foundation
@preconcurrency import AVFoundation
import UniformTypeIdentifiers

/// Copies an imported audio file into a fresh meeting folder, re-encodes
/// it as mono AAC inside `system.caf`, and produces a session pinned to it.
/// The processor path is identical to a live recording with the mic track
/// missing.
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
    /// Create a session for the import, write its meta, and return.
    /// Heavy work (the chunked re-encode of the source audio into
    /// `system.caf`) does NOT happen here — call `reencodeAudio` from a
    /// background context afterwards. This split exists because the old
    /// single-shot `makeSession(from:)` blocked the main thread for the
    /// length of the whole re-encode, beach-balling the UI on long
    /// voice-memo imports. The session lands in `.importing(0)`, then
    /// transitions to `.captured` once the re-encode completes.
    @MainActor
    static func makeShellSession(from source: URL) throws -> MeetingSession {
        let id = UUID()
        // Ensure the local audio folder exists for the re-encode target; the
        // synced meta/transcript folder is created lazily on first write.
        _ = MeetingStorage.audioFolder(for: id)

        // Reading just the file metadata is fast (microseconds) — safe
        // to do on the main actor so we can populate the duration field
        // up-front. The slow part is the per-frame re-encode loop, which
        // moves off-main below.
        let probe = try AVAudioFile(forReading: source)
        let duration = Double(probe.length) / probe.processingFormat.sampleRate

        let title = source.deletingPathExtension().lastPathComponent
        let meta = MeetingMeta(
            id: id,
            title: title.isEmpty ? "Imported audio" : title,
            createdAt: Date(),
            durationSeconds: duration,
            source: .fileImport,
            sourceFilename: source.lastPathComponent,
            audioFiles: .init(mic: nil, system: MeetingStorage.systemFilename),
            speakers: MeetingMeta.defaultImportSpeakers
        )
        try MeetingStorage.writeMeta(meta)
        MeetingsStore.shared.upsert(meta)
        return MeetingSession(forImport: meta)
    }

    /// Re-encode the source audio to mono AAC at `outputURL` (the container
    /// comes from the extension — imports write it into `system.caf`, which
    /// AVFoundation reads/plays just like PCM CAF). Runs off the main actor
    /// so the UI stays responsive while a long voice-memo (hours of audio)
    /// is being decoded + AAC-re-encoded. `progress` is invoked on the
    /// main actor as the import advances (0…1). Caller is expected to
    /// drive `MeetingSession.state = .importing(progress:)` from each
    /// progress tick. `MeetingAudioCompactor` reuses this loop (at
    /// `.utility` priority) to shrink finished recordings in the background.
    nonisolated static func reencodeAudio(
        from source: URL,
        to outputURL: URL,
        priority: TaskPriority = .userInitiated,
        progress: @escaping @Sendable @MainActor (Double) -> Void
    ) async throws {
        try await Task.detached(priority: priority) {
            try? FileManager.default.removeItem(at: outputURL)
            let input = try AVAudioFile(forReading: source)
            let processingFormat = input.processingFormat

            // AAC tops out at 96 kHz and this is speech — when the source is
            // above 48 kHz (a 192 kHz interface clocking the meeting
            // aggregate, or a hi-res import) downsample on the way into the
            // encoder. At or below 48 kHz the source rate is kept as-is.
            let sourceRate = processingFormat.sampleRate
            let targetRate = min(sourceRate, 48_000)
            guard let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false
            ), let encodeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false
            ) else {
                throw NSError(domain: "Dictator.Meetings", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "Couldn't describe the re-encode formats."])
            }
            // The converter carries resampler filter state across chunks, so
            // chunk boundaries don't click. nil when no rate change is needed.
            let converter = targetRate == sourceRate ? nil : AVAudioConverter(from: monoFormat, to: encodeFormat)

            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: targetRate,
                AVNumberOfChannelsKey: 1,
                // 96 kbps mono is transparent for speech; very low-rate
                // sources can't legally carry that much and get 48.
                AVEncoderBitRateKey: targetRate <= 24_000 ? 48_000 : 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            let output = try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )

            let chunkFrames: AVAudioFrameCount = 16_384
            let total = max(AVAudioFrameCount(1), AVAudioFrameCount(input.length))
            var remaining = AVAudioFrameCount(input.length)
            var processed: AVAudioFrameCount = 0
            // Throttle the progress dispatch — one main-actor hop per
            // ~50ms of audio progress is plenty for a smooth meter.
            var lastReported: Double = 0
            // Seed at 0 so the UI shows the bar immediately rather than
            // jumping from "nothing" to "20%".
            await progress(0)
            while remaining > 0 {
                try Task.checkCancellation()
                let toRead = min(chunkFrames, remaining)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: toRead) else { break }
                try input.read(into: buffer, frameCount: toRead)
                if buffer.frameLength == 0 { break }
                let mono = processingFormat.channelCount > 1
                    ? try Self.downmixToMono(buffer, sourceFormat: processingFormat)
                    : buffer
                if let converter {
                    try Self.resample(mono, through: converter, into: output, drain: false)
                } else {
                    try output.write(from: mono)
                }
                let consumed = buffer.frameLength
                remaining = remaining > consumed ? remaining - consumed : 0
                processed += consumed
                let fraction = min(1.0, Double(processed) / Double(total))
                if fraction - lastReported >= 0.02 || remaining == 0 {
                    lastReported = fraction
                    await progress(fraction)
                }
            }
            // Flush the resampler's tail (a filter-length of frames) so the
            // output doesn't come up a hair short of the source duration.
            if let converter {
                try Self.resample(nil, through: converter, into: output, drain: true)
            }
            await progress(1)
        }.value
    }

    /// Push one chunk (or, with `drain`, end-of-stream) through the sample-
    /// rate converter and write whatever it emits. The input block hands the
    /// converter exactly one buffer per call — `.noDataNow` afterwards tells
    /// it to return what it has and wait for the next chunk rather than
    /// treating the stream as finished.
    nonisolated private static func resample(
        _ chunk: AVAudioPCMBuffer?,
        through converter: AVAudioConverter,
        into output: AVAudioFile,
        drain: Bool
    ) throws {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let inFrames = Double(chunk?.frameLength ?? 4096)
        var fed = false
        while true {
            let capacity = AVAudioFrameCount((inFrames * ratio).rounded(.up)) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, inputStatus in
                if let chunk, !fed {
                    fed = true
                    inputStatus.pointee = .haveData
                    return chunk
                }
                inputStatus.pointee = drain ? .endOfStream : .noDataNow
                return nil
            }
            if let convErr { throw convErr }
            if outBuf.frameLength > 0 { try output.write(from: outBuf) }
            // .haveData = the output buffer filled before the feed was
            // consumed — go around again. Anything else means this chunk is
            // fully converted (.inputRanDry) or the stream is flushed.
            guard status == .haveData else { return }
        }
    }

    nonisolated private static func downmixToMono(_ buffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
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
