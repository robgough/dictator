import Foundation
@preconcurrency import AVFoundation

/// Post-capture (or post-import) pipeline. Reads `mic.caf` / `system.caf` off
/// disk, transcribes each track via Parakeet with word-level timestamps,
/// diarizes the system track to attribute remote speech to distinct speakers,
/// and writes a single chronological `transcript.json`.
///
/// Mic words are always attributed to "me" — there's no diarization on the
/// mic track because (a) the user's mic captures one person and (b) running
/// the diarizer on the mic doubles the work for nothing. Only the system
/// track (the remote side of the call) gets the speaker split.
///
/// Diarization failures are non-fatal: if the diarizer can't load or fails
/// mid-process, we still ship the transcript with all system speech bucketed
/// under "Other" — better to surface a flat transcript than nothing.
@MainActor
final class MeetingProcessor {
    /// Per-stage progress callback. The caller maps the stage onto a
    /// MeetingSession state.
    enum Stage: Equatable, Sendable {
        case loadingASR
        case transcribingMic
        case transcribingSystem
        case loadingDiarizer
        case diarizing
        case writingTranscript
    }

    /// `meetingDiarizationModelID` is wired in MeetingProcessor rather than
    /// surfaced as a settings field — v0.2 only ships one diarization bundle
    /// and the catalog id is the single source of truth.
    private let diarizationModelID = ModelCatalog.defaultDiarization.id

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

        var micWords: [SpeakerAttributedWord] = []
        var systemWords: [SpeakerAttributedWord] = []
        var micDuration: Double = 0
        var systemDuration: Double = 0

        // Mic track — single speaker ("me"), no diarization. Old meetings
        // captured before the v0.1 fix sometimes wrote meta claiming a mic
        // file that was never created, so check the filesystem too.
        if let micURL = session.micFileURL,
           FileManager.default.fileExists(atPath: micURL.path) {
            onProgress(.transcribingMic, 0)
            let (words, fallbackText, duration) = try await transcribeTrack(url: micURL, modelID: parakeetModelID)
            onProgress(.transcribingMic, 1)
            micDuration = duration
            if !words.isEmpty {
                micWords = words.map { SpeakerAttributedWord(start: $0.start, end: $0.end, text: $0.text, speakerId: "me") }
            } else if !fallbackText.isEmpty {
                // No token timings (model didn't surface them) — fall back to
                // a single faux-word spanning the whole track so the merge
                // step still emits something. The text comes through intact;
                // we just lose word-precision search for this clip.
                micWords = [SpeakerAttributedWord(start: 0, end: duration, text: fallbackText, speakerId: "me")]
            }
        }

        // System track — word-aligned ASR + diarization. The diarizer is the
        // only thing that lets us put multiple speakers in the transcript.
        var diarFailureReason: String?
        var discoveredSpeakerIDs: [String] = []  // in encounter order, "speaker_1", "speaker_2", …

        if let systemURL = session.systemFileURL,
           FileManager.default.fileExists(atPath: systemURL.path) {
            onProgress(.transcribingSystem, 0)
            let (words, fallbackText, duration) = try await transcribeTrack(url: systemURL, modelID: parakeetModelID)
            onProgress(.transcribingSystem, 1)
            systemDuration = duration

            if !words.isEmpty {
                // Try to diarize. Failures here just mean every word is
                // attributed to a single "other" speaker.
                onProgress(.loadingDiarizer, 0)
                var diarSegs: [DiarizationSegment] = []
                do {
                    try await DiarizerServiceHolder.shared.ensureLoaded(modelID: diarizationModelID)
                    onProgress(.loadingDiarizer, 1)
                    onProgress(.diarizing, 0)
                    diarSegs = try await DiarizerServiceHolder.shared.diarize(
                        audioFileAt: systemURL,
                        modelID: diarizationModelID
                    )
                    onProgress(.diarizing, 1)
                } catch {
                    diarFailureReason = error.localizedDescription
                    NSLog("[Dictator] Diarizer failed for meeting \(session.id): \(error)")
                    onProgress(.diarizing, 1)
                }

                if diarSegs.isEmpty {
                    // No diarizer output → everything is "other".
                    systemWords = words.map {
                        SpeakerAttributedWord(start: $0.start, end: $0.end, text: $0.text, speakerId: "other")
                    }
                    discoveredSpeakerIDs = ["other"]
                } else {
                    let (attributed, speakerOrder) = Self.attributeSpeakers(words: words, segments: diarSegs)
                    systemWords = attributed
                    discoveredSpeakerIDs = speakerOrder
                }
            } else if !fallbackText.isEmpty {
                systemWords = [SpeakerAttributedWord(start: 0, end: duration, text: fallbackText, speakerId: "other")]
                discoveredSpeakerIDs = ["other"]
            }
        }

        onProgress(.writingTranscript, 0)

        // Merge mic + system words by start time, then split into per-speaker
        // segments wherever the speaker changes or a long gap (≥700ms) opens.
        let allWords = (micWords + systemWords).sorted { $0.start < $1.start }
        let segments = Self.buildSegments(from: allWords)
        let transcript = MeetingTranscript(segments: segments)
        try MeetingStorage.writeTranscript(transcript, for: session.id)

        // Rebuild the meta's speakers list from what actually appeared in the
        // transcript. We keep stable colors keyed by id so an "other" meeting
        // (diarizer failed) and a multi-speaker one don't drift visually.
        var meta = session.meta
        meta.durationSeconds = max(micDuration, systemDuration)
        meta.speakers = Self.buildSpeakerPalette(
            includeMe: !micWords.isEmpty,
            systemSpeakerIDs: discoveredSpeakerIDs
        )
        if let reason = diarFailureReason {
            // Surface the failure in NSLog only — we don't have a per-meeting
            // notes field yet, and a clean fallback transcript is more useful
            // than a hard error. Worth revisiting if multiple users hit this.
            NSLog("[Dictator] Meeting \(session.id) completed without diarization: \(reason)")
        }
        try MeetingStorage.writeMeta(meta)
        session.meta = meta
        onProgress(.writingTranscript, 1)
    }

    // MARK: - Track transcription

    /// Returns (words, fallbackText, durationSeconds). If the model produces
    /// no token timings, `words` is empty and `fallbackText` carries the raw
    /// transcript so the caller can still emit a single coarse segment.
    private func transcribeTrack(url: URL, modelID: String) async throws -> ([TimedWord], String, Double) {
        let samples = try Self.loadMono16k(from: url)
        let duration = Double(samples.count) / 16_000
        guard !samples.isEmpty else { return ([], "", duration) }
        let words = try await ParakeetServiceHolder.shared.transcribeWithTimestamps(samples: samples, modelID: modelID)
        if !words.isEmpty { return (words, "", duration) }
        let text = try await ParakeetServiceHolder.shared.transcribe(samples: samples, modelID: modelID)
        return ([], text.trimmingCharacters(in: .whitespacesAndNewlines), duration)
    }

    // MARK: - Diarization alignment

    /// Attribute each word to a speaker based on the diarizer's segments.
    /// Speakers are remapped from FluidAudio's opaque cluster labels to
    /// our stable "speaker_1", "speaker_2", … in encounter order so the
    /// rendered transcript reads naturally ("speaker_1" speaks first).
    nonisolated static func attributeSpeakers(
        words: [TimedWord],
        segments: [DiarizationSegment]
    ) -> (words: [SpeakerAttributedWord], orderedIDs: [String]) {
        guard !segments.isEmpty else { return ([], []) }
        let sortedSegments = segments.sorted { $0.start < $1.start }

        // Stable cluster-label → "speaker_N" mapping, populated as we
        // encounter each new label.
        var clusterToOurID: [String: String] = [:]
        var orderedIDs: [String] = []
        func registerLabel(_ label: String) -> String {
            if let existing = clusterToOurID[label] { return existing }
            let ourID = "speaker_\(orderedIDs.count + 1)"
            clusterToOurID[label] = ourID
            orderedIDs.append(ourID)
            return ourID
        }

        var attributed: [SpeakerAttributedWord] = []
        attributed.reserveCapacity(words.count)
        var lastSpeakerID = "speaker_1"  // fallback used before the first match
        for word in words {
            let mid = (word.start + word.end) / 2
            // Linear walk is fine — system tracks rarely have more than a
            // few hundred diarizer segments and we visit each word once.
            // If profiling shows this matters, swap to binary search.
            let covering = sortedSegments.first(where: { mid >= $0.start && mid <= $0.end })
            if let covering {
                lastSpeakerID = registerLabel(covering.speakerLabel)
            } else if let nearest = nearestSegment(to: mid, in: sortedSegments) {
                lastSpeakerID = registerLabel(nearest.speakerLabel)
            }
            attributed.append(SpeakerAttributedWord(
                start: word.start,
                end: word.end,
                text: word.text,
                speakerId: lastSpeakerID
            ))
        }

        return (attributed, orderedIDs)
    }

    nonisolated private static func nearestSegment(
        to time: TimeInterval,
        in segments: [DiarizationSegment]
    ) -> DiarizationSegment? {
        var best: DiarizationSegment?
        var bestDist = Double.infinity
        for seg in segments {
            let dist: Double
            if time < seg.start { dist = seg.start - time }
            else if time > seg.end { dist = time - seg.end }
            else { dist = 0 }
            if dist < bestDist {
                bestDist = dist
                best = seg
            }
        }
        return best
    }

    // MARK: - Segment building

    /// Words are already sorted by start time and tagged with speakerId.
    /// We split into one segment per speaker turn — a new segment begins
    /// whenever the speaker changes or a ≥700ms gap opens (long pauses
    /// shouldn't be glued into one wall of text even from the same speaker).
    nonisolated static func buildSegments(from words: [SpeakerAttributedWord]) -> [MeetingTranscriptSegment] {
        guard !words.isEmpty else { return [] }
        let gapThreshold: Double = 0.7

        var segments: [MeetingTranscriptSegment] = []
        var bucket: [SpeakerAttributedWord] = [words[0]]

        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let text = bucket.map { $0.text }.joined(separator: " ")
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(MeetingTranscriptSegment(
                start: first.start,
                end: last.end,
                speakerId: first.speakerId,
                text: trimmed,
                words: bucket.map { TranscriptWord(start: $0.start, end: $0.end, text: $0.text) }
            ))
        }

        for word in words.dropFirst() {
            let last = bucket.last!
            let speakerChanged = word.speakerId != last.speakerId
            let longGap = (word.start - last.end) >= gapThreshold
            if speakerChanged || longGap {
                flush()
                bucket = [word]
            } else {
                bucket.append(word)
            }
        }
        flush()
        return segments
    }

    // MARK: - Speaker palette

    /// Stable hex palette indexed off speaker number. "me" always gets the
    /// brand blue; "other" (diarizer-failed fallback) keeps the v0.1 orange
    /// so older meetings render the same way.
    nonisolated static let speakerPalette: [String] = [
        "#ED7D31",  // orange
        "#70AD47",  // green
        "#A5A5A5",  // grey
        "#9966CC",  // purple
        "#E15554",  // red
        "#4B89DC",  // sky blue
        "#F4B400",  // amber
    ]

    nonisolated static func buildSpeakerPalette(
        includeMe: Bool,
        systemSpeakerIDs: [String]
    ) -> [MeetingMeta.Speaker] {
        var speakers: [MeetingMeta.Speaker] = []
        if includeMe {
            speakers.append(.init(id: "me", displayName: "Me", colorHex: "#5B9BD5", isMe: true))
        }
        for (idx, id) in systemSpeakerIDs.enumerated() {
            let displayName: String
            if id == "other" {
                displayName = "Other"
            } else {
                displayName = "Speaker \(idx + 1)"
            }
            let color = speakerPalette[idx % speakerPalette.count]
            speakers.append(.init(id: id, displayName: displayName, colorHex: color, isMe: false))
        }
        return speakers
    }

    // MARK: - Audio loading

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

/// Internal-only intermediate. Held only during a `MeetingProcessor.run`
/// invocation; never persisted as such — the `words[]` on each
/// `MeetingTranscriptSegment` is what hits disk.
struct SpeakerAttributedWord: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    let speakerId: String
}
