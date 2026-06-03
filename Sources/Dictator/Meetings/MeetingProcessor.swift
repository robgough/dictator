import Foundation
import Accelerate
@preconcurrency import AVFoundation

/// Post-capture (or post-import) pipeline. Reads `mic.caf` / `system.caf` off
/// disk, transcribes each track via Parakeet with word-level timestamps,
/// diarizes BOTH tracks to attribute speech to distinct speakers, merges
/// clusters across the two tracks into one global speaker space, and writes
/// a single chronological `transcript.json`.
///
/// Multi-track speaker merging strategy (chosen July 2026 to fix the wholesale
/// "mic=me" assumption that broke for in-room recordings or shared machines):
///
/// 1. Diarize mic and system tracks independently. Each produces opaque cluster
///    labels (`S1`, `S2`, …) whose identity is local to that track — `S1` on
///    the mic is not the same person as `S1` on the system.
/// 2. Compare cluster mean embeddings across tracks via cosine similarity.
///    FluidAudio's `OfflineDiarizerManager.process` returns a `speakerDatabase`
///    of `[clusterID: [Float]]` — these are unit-normalised speaker embeddings,
///    so cosine similarity gives a clean cross-track match score. Threshold is
///    0.78, slightly looser than the same-track cluster threshold to account
///    for codec / AEC / mic-vs-speaker characteristic differences in how the
///    same person sounds across the two recordings.
/// 3. Pick the dominant mic cluster (the one with the most speech time) as
///    "me". For live recordings this is right >95% of the time — the user is
///    almost always the loudest, longest-speaking voice on their own mic.
/// 4. Remaining mic clusters and all system clusters are unified — when a
///    cross-track centroid match exists, they share the same `speaker_N` slot;
///    otherwise they get a fresh one in encounter order.
///
/// Co-occurrence was considered as a fallback when centroids aren't available,
/// but in practice FluidAudio always returns a `speakerDatabase` for any audio
/// that produced segments, so we treat a missing centroid as "skip this match
/// and let it land in its own slot" rather than firing a different algorithm.
///
/// Imports (mic=nil, system only): falls back to the single-track path with
/// no behaviour change from v0.2.
///
/// Diarization failures are non-fatal: if the diarizer can't load or fails
/// mid-process, we still ship the transcript with all that-track speech
/// bucketed under "Other" — better to surface a flat transcript than nothing.
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

    /// When true, `run` filters mic words that look like echoes of system
    /// words (same token within ±300 ms). Wired from
    /// `DictatorSettings.meetingDedupeMicEchoes` by the caller; default ON.
    /// Held on the processor rather than read off Settings inline so the
    /// dedup is testable without spinning up the settings stack.
    var dedupeMicEchoes: Bool = true

    /// Run the pipeline. Updates `meta.json` with the final duration +
    /// speaker list, writes `transcript.json`. Throws on Parakeet load /
    /// ASR failure; the caller decides whether to surface that or retry.
    func run(
        session: MeetingSession,
        parakeetModelID: String,
        onProgress: @escaping @MainActor (Stage, Double) -> Void
    ) async throws {
        onProgress(.loadingASR, 0)
        // Meeting-dedicated ASR (shares the dictation weights when warm) so the
        // whole-track transcription below runs on its own serial actor and can't
        // block a dictation the user fires while this post-pass is running.
        let parakeet = MeetingParakeetServiceHolder.shared
        try await parakeet.ensureLoaded(modelID: parakeetModelID)
        onProgress(.loadingASR, 1)

        var micTimedWords: [TimedWord] = []
        var systemTimedWords: [TimedWord] = []
        var micFallbackText: String = ""
        var systemFallbackText: String = ""
        var micDuration: Double = 0
        var systemDuration: Double = 0

        // ── Load both tracks as 16 kHz mono ──────────────────────────────
        // System first — it's the reference the mic-bleed gate aligns against.
        var micSamples: [Float] = []
        var systemSamples: [Float] = []
        if let systemURL = session.systemFileURL,
           FileManager.default.fileExists(atPath: systemURL.path) {
            systemSamples = (try? Self.loadMono16k(from: systemURL)) ?? []
            systemDuration = Double(systemSamples.count) / 16_000
        }
        // Mic track. Old meetings captured before the v0.1 fix sometimes wrote
        // meta claiming a mic file that was never created, so check the FS too.
        if let micURL = session.micFileURL,
           FileManager.default.fileExists(atPath: micURL.path) {
            micSamples = (try? Self.loadMono16k(from: micURL)) ?? []
            micDuration = Double(micSamples.count) / 16_000
        }

        // ── Mic-bleed gate ───────────────────────────────────────────────
        // With a sensitive mic and no headphones the mic captures the remote
        // audio bleeding out of the speakers. That bleed is a delayed,
        // heavily-attenuated copy of the system track, so we cancel it in the
        // AUDIO domain — before transcription AND diarization — using the system
        // track as the reference. This is far more robust than the downstream
        // text-level dedup, which fails because acoustically-degraded bleed
        // transcribes to *different* words than the clean system track and so
        // never matches. Self-disables when the two tracks aren't correlated
        // (headphones / clean setup). Gated by the same "drop my mic's echoes"
        // setting that controls the text dedup.
        if dedupeMicEchoes, !micSamples.isEmpty, !systemSamples.isEmpty {
            let gate = Self.gateMicBleed(mic: micSamples, system: systemSamples, sampleRate: 16_000)
            NSLog("[Dictator] Mic-bleed gate: medianRatio=\(String(format: "%.2f", gate.medianRatio)) fraction=\(String(format: "%.2f", gate.fraction)) dropped=\(String(format: "%.0f%%", gate.droppedFraction * 100)) (\(gate.applied ? "applied" : "skipped — mic as loud as the call / no bleed"))")
            micSamples = gate.gated
        }

        // ── Transcription pass on each track ─────────────────────────────
        if !micSamples.isEmpty {
            onProgress(.transcribingMic, 0)
            (micTimedWords, micFallbackText) = try await transcribeSamples(micSamples, modelID: parakeetModelID)
            onProgress(.transcribingMic, 1)
        }
        if !systemSamples.isEmpty {
            onProgress(.transcribingSystem, 0)
            (systemTimedWords, systemFallbackText) = try await transcribeSamples(systemSamples, modelID: parakeetModelID)
            onProgress(.transcribingSystem, 1)
        }

        // ── Diarization pass on each track ───────────────────────────────
        // Diarize from the same (gated, for the mic) samples we transcribed, so
        // the "me" cluster is built from de-bled audio. Loaded diarizer is
        // reused for both calls — load time is real (several seconds).
        var micDiar: DiarizationOutput?
        var systemDiar: DiarizationOutput?
        var diarFailureReason: String?

        let needsDiar = (!micTimedWords.isEmpty && !micSamples.isEmpty)
            || (!systemTimedWords.isEmpty && !systemSamples.isEmpty)
        if needsDiar {
            do {
                onProgress(.loadingDiarizer, 0)
                try await DiarizerServiceHolder.shared.ensureLoaded(modelID: diarizationModelID)
                onProgress(.loadingDiarizer, 1)

                onProgress(.diarizing, 0)
                if !micTimedWords.isEmpty, !micSamples.isEmpty {
                    micDiar = try await DiarizerServiceHolder.shared.diarize(
                        samples: micSamples,
                        modelID: diarizationModelID,
                        trackLabel: "mic"
                    )
                }
                // Half-way bump so the progress UI moves between the two tracks.
                onProgress(.diarizing, 0.5)
                if !systemTimedWords.isEmpty, !systemSamples.isEmpty {
                    systemDiar = try await DiarizerServiceHolder.shared.diarize(
                        samples: systemSamples,
                        modelID: diarizationModelID,
                        trackLabel: "system"
                    )
                }
                onProgress(.diarizing, 1)
            } catch {
                diarFailureReason = error.localizedDescription
                NSLog("[Dictator] Diarizer failed for meeting \(session.id): \(error)")
                onProgress(.diarizing, 1)
            }
        }

        // Transcription and diarization are done — they were the only consumers
        // of the decoded tracks. Release them now (each is ~230 MB/hour) so the
        // ~1 GB of a 2-hour meeting's audio isn't still resident through the
        // attribution + LLM tail, where back-to-back long meetings would
        // otherwise crowd memory and push the machine toward swap.
        micSamples = []
        systemSamples = []

        // ── Speaker-space unification ────────────────────────────────────
        // Build one global speaker space from the (possibly two) per-track
        // diarizer outputs. The mapping tells us which final speaker_N (or
        // "me") each track's opaque cluster label resolves to.
        let unified = Self.unifySpeakerSpace(micDiar: micDiar, systemDiar: systemDiar)

        // ── Word attribution ─────────────────────────────────────────────
        var micWords: [SpeakerAttributedWord] = []
        var systemWords: [SpeakerAttributedWord] = []

        // Mic words. If diarization is available we run the overlap-aware
        // attribution and remap via the unified mapping. Otherwise we fall
        // back to the v0.2 behaviour of attributing all mic speech to "me".
        if !micTimedWords.isEmpty {
            if let micDiar, !micDiar.segments.isEmpty {
                micWords = Self.attributeWords(
                    words: micTimedWords,
                    segments: micDiar.segments,
                    clusterToSpeakerID: unified.micMapping,
                    defaultSpeakerID: "me"
                )
            } else {
                micWords = micTimedWords.map {
                    SpeakerAttributedWord(start: $0.start, end: $0.end, text: $0.text, speakerId: "me")
                }
            }
        } else if !micFallbackText.isEmpty {
            // No token timings (model didn't surface them) — fall back to
            // a single faux-word spanning the whole track so the merge
            // step still emits something. The text comes through intact;
            // we just lose word-precision search for this clip.
            micWords = [SpeakerAttributedWord(start: 0, end: micDuration, text: micFallbackText, speakerId: "me")]
        }

        // System words.
        if !systemTimedWords.isEmpty {
            if let systemDiar, !systemDiar.segments.isEmpty {
                systemWords = Self.attributeWords(
                    words: systemTimedWords,
                    segments: systemDiar.segments,
                    clusterToSpeakerID: unified.systemMapping,
                    defaultSpeakerID: "other"
                )
            } else {
                systemWords = systemTimedWords.map {
                    SpeakerAttributedWord(start: $0.start, end: $0.end, text: $0.text, speakerId: "other")
                }
            }
        } else if !systemFallbackText.isEmpty {
            systemWords = [SpeakerAttributedWord(start: 0, end: systemDuration, text: systemFallbackText, speakerId: "other")]
        }

        onProgress(.writingTranscript, 0)

        // Belt-and-braces ASR-side dedup. When the user isn't wearing
        // headphones, their mic captures the remote speakers and the same
        // words land on both tracks. AEC catches most of it; this pass
        // mops up residual echoes (Bluetooth latency variance, AGC stomp).
        // The system track wins for any echo — it's the canonical copy.
        if dedupeMicEchoes, !micWords.isEmpty, !systemWords.isEmpty {
            let originalCount = micWords.count
            micWords = Self.dedupeMicEchoes(micWords: micWords, systemWords: systemWords)
            let dropped = originalCount - micWords.count
            NSLog("[Dictator] Mic-echo dedup: kept \(micWords.count) of \(originalCount) mic words (dropped \(dropped))")
        }

        // Merge mic + system words by start time. From here on we work on the
        // single merged timeline.
        var allWords = (micWords + systemWords).sorted { $0.start < $1.start }

        // Fold away phantom speakers — a diarizer cluster (or a stray "me" from
        // a single surviving bleed word) that contributed only a token or two
        // of speech to the whole meeting. These show up as a spurious chip with
        // one misattributed word; the canonical example is a listen-only call
        // where exactly one mic word slips past echo-dedup and seeds a "Me"
        // speaker. Raising the clustering threshold (see DiarizerService) also
        // surfaces the odd ~2 s blip cluster, so this guard pairs with it.
        // Conservative on purpose: only ≤2-word, ≤2 s speakers are folded into
        // the temporally-nearest surviving speaker, so a real brief interjection
        // ("yeah, makes sense") is never merged away.
        allWords = Self.foldTrivialSpeakers(words: allWords)

        // Decide the final speaker ID list in encounter order along the merged,
        // folded timeline. A speaker survives here only if it actually kept
        // words after echo-dedup and trivial-fold — so a mic track that was
        // entirely bleed doesn't seed a phantom "Me" on a listen-only meeting.
        let usedSpeakerIDs = Self.discoveredSpeakerIDsInOrder(words: allWords)
        let micUniqueCount = micDiar?.clusterCentroids.count ?? 0
        let systemUniqueCount = systemDiar?.clusterCentroids.count ?? 0
        NSLog("[Dictator] Diarizer[merged]: micClusters=\(micUniqueCount) systemClusters=\(systemUniqueCount) finalSpeakers=\(usedSpeakerIDs.count) ids=\(usedSpeakerIDs.joined(separator: ","))")

        // Split the merged timeline into per-speaker segments wherever the
        // speaker changes or a long gap (≥700ms) opens.
        var segments = Self.buildSegments(from: allWords)
        // Deterministic vocabulary pass — the same user dictionary dictation
        // uses (names, jargon, preferred spellings), applied whole-word to each
        // segment so the transcript AND the notes (built from it) pick up the
        // corrections. No-op when the dictionary is empty.
        let vocab = VocabularyStore.shared.entries
        if !vocab.isEmpty {
            segments = segments.map { seg in
                var s = seg
                s.text = Vocabulary.apply(vocab, to: seg.text)
                return s
            }
        }
        let transcript = MeetingTranscript(segments: segments)
        try MeetingStorage.writeTranscript(transcript, for: session.id)

        // Rebuild the meta's speakers list from what actually appeared in the
        // transcript. We keep stable colors keyed by id so an "other" meeting
        // (diarizer failed) and a multi-speaker one don't drift visually.
        var meta = session.meta
        meta.durationSeconds = max(micDuration, systemDuration)
        meta.speakers = Self.buildSpeakerPalette(speakerIDs: usedSpeakerIDs)
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

    /// Returns (words, fallbackText). If the model produces no token timings,
    /// `words` is empty and `fallbackText` carries the raw transcript so the
    /// caller can still emit a single coarse segment.
    private func transcribeSamples(_ samples: [Float], modelID: String) async throws -> ([TimedWord], String) {
        guard !samples.isEmpty else { return ([], "") }
        let words = try await MeetingParakeetServiceHolder.shared.transcribeWithTimestamps(samples: samples, modelID: modelID)
        if !words.isEmpty { return (words, "") }
        let text = try await MeetingParakeetServiceHolder.shared.transcribe(samples: samples, modelID: modelID)
        return ([], text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Mic-bleed gate

    /// Outcome of `gateMicBleed`. `gated` is the mic with bleed frames silenced;
    /// the rest are diagnostics for the log.
    nonisolated struct BleedGateResult: Sendable {
        let gated: [Float]
        let droppedFraction: Double
        /// Median of (mic / windowed-system) across mic-active frames — the
        /// "how quiet does the mic run vs the call?" signal the gate keys off.
        let medianRatio: Double
        /// The bleed threshold actually used (0 when the gate didn't engage).
        let fraction: Double
        /// False when the mic, whenever it's active, is about as loud as the
        /// call — i.e. you're speaking or on headphones, no bleed to remove.
        let applied: Bool
    }

    /// Gate tuning. A mic frame is bleed when it sits below `fraction`× the
    /// loudest system frame within ±`windowRadius` (the window covers the
    /// speaker→mic delay + room reverb without having to estimate it). The
    /// fraction adapts to how bleed-dominated the recording is:
    ///  - `enableMedianRatio`: if the mic, when active, is typically at least
    ///    this fraction of the system, there's no bleed pattern (you're
    ///    speaking / on headphones) — leave the mic untouched.
    ///  - `aggressiveMedianRatio`: if the mic is *almost always* far quieter
    ///    than the system (you're essentially just listening), use the
    ///    aggressive fraction to catch louder bleed too; otherwise stay
    ///    conservative so a quieter-than-the-call voice isn't eaten.
    private nonisolated static let bleedSystemFloor: Float = 0.01
    private nonisolated static let bleedMicFloor: Float = 0.002
    private nonisolated static let bleedWindowRadius = 20            // ±200 ms
    private nonisolated static let bleedEnableMedianRatio: Float = 0.7
    private nonisolated static let bleedAggressiveMedianRatio: Float = 0.2
    private nonisolated static let bleedFractionNormal: Float = 0.4
    private nonisolated static let bleedFractionAggressive: Float = 0.65

    /// Remove remote-speaker bleed from the mic using the system track as a
    /// reference. Decides whether there's bleed — and how aggressively to gate —
    /// from the LEVEL relationship between the two tracks, which (unlike a
    /// delay/correlation estimate) needs no clean run of bleed and so works even
    /// when the mic was on for only a couple of seconds. Silences any mic frame
    /// far quieter than the loudest system audio in a ±200 ms window around it;
    /// kept regions are dilated and the gain is smoothed + ramped per sample, so
    /// there are no clicks for the transcriber to mishear.
    ///
    /// Honest limitation: a bleed transient that momentarily reaches the call's
    /// own level (e.g. a loud word leaking in at ≈1× the system) is
    /// level-indistinguishable from your own voice and survives — catching it
    /// needs content matching, which the downstream text dedup attempts.
    nonisolated static func gateMicBleed(mic: [Float], system: [Float], sampleRate: Double) -> BleedGateResult {
        let sr = Int(sampleRate)
        let frame = max(1, sr / 100)   // 10 ms analysis frame
        guard mic.count >= frame, system.count >= frame else {
            return BleedGateResult(gated: mic, droppedFraction: 0, medianRatio: 9, fraction: 0, applied: false)
        }
        let micEnv = rmsEnvelope(mic, frame: frame)
        let sysEnv = rmsEnvelope(system, frame: frame)
        let n = min(micEnv.count, sysEnv.count)
        let radius = bleedWindowRadius

        // Loudest system frame within ±radius of `i` — covers the speaker→mic
        // delay and reverb tail without estimating either.
        func windowedSystem(_ i: Int) -> Float {
            var s: Float = 0
            let lo = max(0, i - radius), hi = min(n - 1, i + radius)
            var j = lo
            while j <= hi { s = max(s, sysEnv[j]); j += 1 }
            return s
        }

        // How quiet does the mic run vs the call when it's active? The median
        // ratio decides engage / how-aggressive.
        var ratios: [Float] = []
        for i in 0..<n where micEnv[i] > bleedMicFloor {
            let s = windowedSystem(i)
            if s > bleedSystemFloor { ratios.append(micEnv[i] / s) }
        }
        guard ratios.count >= 10 else {
            return BleedGateResult(gated: mic, droppedFraction: 0, medianRatio: 9, fraction: 0, applied: false)
        }
        ratios.sort()
        let median = ratios[ratios.count / 2]
        guard median < bleedEnableMedianRatio else {
            return BleedGateResult(gated: mic, droppedFraction: 0, medianRatio: Double(median), fraction: 0, applied: false)
        }
        let fraction: Float = median < bleedAggressiveMedianRatio ? bleedFractionAggressive : bleedFractionNormal

        var keep = [Float](repeating: 1, count: n)
        var dropped = 0
        for i in 0..<n {
            let s = windowedSystem(i)
            if s > bleedSystemFloor && micEnv[i] < fraction * s {
                keep[i] = 0
                dropped += 1
            }
        }
        // Dilate the KEEP regions by one frame so a speech onset adjacent to
        // bleed isn't clipped, then 3-tap smooth so transitions fade.
        keep = dilateKeep(keep)
        keep = smooth3(keep)

        // Apply the smoothed gain, linearly interpolating between adjacent frame
        // gains so each 10 ms boundary fades rather than steps.
        var gated = mic
        gated.withUnsafeMutableBufferPointer { out in
            for i in 0..<n {
                let g0 = keep[i]
                let g1 = (i + 1 < n) ? keep[i + 1] : g0
                if g0 >= 0.999 && g1 >= 0.999 { continue }   // fully kept — skip
                let start = i * frame
                for k in 0..<frame {
                    let t = Float(k) / Float(frame)
                    out[start + k] *= g0 + (g1 - g0) * t
                }
            }
        }
        return BleedGateResult(
            gated: gated,
            droppedFraction: Double(dropped) / Double(n),
            medianRatio: Double(median),
            fraction: Double(fraction),
            applied: true
        )
    }

    /// Per-frame RMS envelope.
    private nonisolated static func rmsEnvelope(_ x: [Float], frame: Int) -> [Float] {
        let n = x.count / frame
        guard n > 0 else { return [] }
        var env = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + i * frame, 1, &ms, vDSP_Length(frame))
                env[i] = ms.squareRoot()
            }
        }
        return env
    }

    /// Max-filter (radius 1) over a 0/1 keep mask — grows the kept regions by a
    /// frame on each side so speech onsets next to bleed aren't clipped.
    private nonisolated static func dilateKeep(_ g: [Float]) -> [Float] {
        guard g.count > 2 else { return g }
        var out = g
        for i in g.indices {
            let lo = i > 0 ? g[i - 1] : g[i]
            let hi = i < g.count - 1 ? g[i + 1] : g[i]
            out[i] = max(g[i], max(lo, hi))
        }
        return out
    }

    /// 3-tap moving average — turns the 0/1 mask into gentle fades.
    private nonisolated static func smooth3(_ g: [Float]) -> [Float] {
        guard g.count > 2 else { return g }
        var out = g
        for i in 1..<(g.count - 1) {
            out[i] = (g[i - 1] + g[i] + g[i + 1]) / 3
        }
        return out
    }

    // MARK: - Diarization alignment

    /// Overlap-aware word attribution. With `exclusiveSegments = false` set on
    /// the diarizer config, a word's midpoint can fall inside multiple
    /// segments simultaneously (two or more speakers active at once). When
    /// that happens we pick the segment whose *midpoint* is closest to the
    /// word's midpoint — a cheap proxy for "which speaker is this word
    /// centered on?" that tends to favour the dominant speaker for any given
    /// instant. A single word always ends up attributed to exactly one
    /// speaker; we don't try to split a word across speakers.
    ///
    /// `clusterToSpeakerID` maps the diarizer's opaque cluster label (e.g.
    /// `"S1"`) to the final unified speaker ID (`"me"`, `"speaker_2"`, …) —
    /// computed once in `unifySpeakerSpace` so mic and system tracks share
    /// the same speaker IDs when the centroids matched.
    nonisolated static func attributeWords(
        words: [TimedWord],
        segments: [DiarizationSegment],
        clusterToSpeakerID: [String: String],
        defaultSpeakerID: String
    ) -> [SpeakerAttributedWord] {
        guard !segments.isEmpty else {
            return words.map {
                SpeakerAttributedWord(start: $0.start, end: $0.end, text: $0.text, speakerId: defaultSpeakerID)
            }
        }
        let sortedSegments = segments.sorted { $0.start < $1.start }

        var attributed: [SpeakerAttributedWord] = []
        attributed.reserveCapacity(words.count)
        var lastSpeakerID = defaultSpeakerID
        for word in words {
            let wordMid = (word.start + word.end) / 2

            // Find all segments overlapping the word's midpoint. With
            // overlap enabled there can be 0, 1, 2 or 3 — at most 3 because
            // pyannote community-1 emits per-frame activity for 3 speakers.
            var bestLabel: String?
            var bestCenterDistance = Double.infinity
            for seg in sortedSegments {
                if seg.end < word.start { continue }       // strictly before
                if seg.start > word.end { break }           // strictly after; sorted by start
                if wordMid >= seg.start && wordMid <= seg.end {
                    let segMid = (seg.start + seg.end) / 2
                    let dist = abs(segMid - wordMid)
                    if dist < bestCenterDistance {
                        bestCenterDistance = dist
                        bestLabel = seg.speakerLabel
                    }
                }
            }

            // No segment covered the midpoint — fall back to the nearest
            // segment in time. Bridges short silences and ASR/diar timing
            // disagreements without inventing a new speaker.
            if bestLabel == nil, let nearest = nearestSegment(to: wordMid, in: sortedSegments) {
                bestLabel = nearest.speakerLabel
            }

            if let label = bestLabel {
                lastSpeakerID = clusterToSpeakerID[label] ?? lastSpeakerID
            }

            attributed.append(SpeakerAttributedWord(
                start: word.start,
                end: word.end,
                text: word.text,
                speakerId: lastSpeakerID
            ))
        }

        return attributed
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

    // MARK: - Cross-track speaker unification

    /// Result of merging two per-track diarizer outputs into one global
    /// speaker space. `micMapping` and `systemMapping` are the per-track
    /// cluster-label → unified-speaker-ID lookups consumed by
    /// `attributeWords`. `discoveredOrder` carries the encounter order of
    /// unified IDs across both tracks (mic clusters first, then system
    /// clusters that didn't match an existing one).
    nonisolated struct UnifiedSpeakerSpace: Sendable {
        let micMapping: [String: String]
        let systemMapping: [String: String]
        let discoveredOrder: [String]
    }

    /// Unify the two per-track diarizer outputs into a single speaker space.
    ///
    /// The dominant mic cluster (most total speech) becomes "me". Other mic
    /// clusters and system clusters are assigned to `speaker_N` slots in
    /// encounter order. Whenever a cross-track cluster's centroid is close
    /// (cosine similarity ≥ matchThreshold) to a cluster already in the
    /// unified space, we reuse that slot — that's how the same physical
    /// person bleeding across mic and system tracks gets recognised.
    nonisolated static func unifySpeakerSpace(
        micDiar: DiarizationOutput?,
        systemDiar: DiarizationOutput?
    ) -> UnifiedSpeakerSpace {
        // Cosine-similarity threshold for declaring two clusters (from
        // different tracks) to be the same physical speaker. Same-track
        // clustering uses the FluidAudio `clustering.threshold` of 0.5 in
        // VBx distance space; cross-track is a different problem — the
        // speaker sounds slightly different through their own mic vs the
        // speaker output, so we need to be looser. 0.78 cosine similarity
        // is the ballpark empirically used in pyannote-derived pipelines
        // for "probably the same person, different channel" matching.
        let matchThreshold: Float = 0.78

        var micMapping: [String: String] = [:]
        var systemMapping: [String: String] = [:]
        var orderedIDs: [String] = []
        // Centroids of unified slots, keyed by unified ID — used to match
        // a fresh cross-track cluster against everyone we've seen so far.
        var unifiedCentroids: [String: [Float]] = [:]

        // Step 1: pick the dominant mic cluster (longest total speech time)
        // as "me". Heuristic — right >95% of the time for live recordings
        // because the user is the loudest and longest-speaking voice on
        // their own mic. Wrong only for shared-machine or in-room cases
        // where someone else dominates the mic; users can rename "me" to
        // the actual speaker in the chip UI.
        var meCluster: String?
        if let micDiar, !micDiar.segments.isEmpty {
            let totals = Dictionary(grouping: micDiar.segments, by: { $0.speakerLabel })
                .mapValues { $0.reduce(0.0) { $0 + ($1.end - $1.start) } }
            meCluster = totals.max(by: { $0.value < $1.value })?.key
        }

        if let meCluster {
            micMapping[meCluster] = "me"
            orderedIDs.append("me")
            if let centroid = micDiar?.clusterCentroids[meCluster] {
                unifiedCentroids["me"] = centroid
            }
        }

        // Helper that registers a cluster — either against an existing
        // unified slot whose centroid matches, or as a fresh speaker_N.
        // Returns the unified ID it ended up bound to.
        func register(label: String, centroid: [Float]?) -> String {
            // Try to match against any existing unified slot.
            if let centroid {
                var bestID: String?
                var bestSim: Float = matchThreshold
                for (uid, uc) in unifiedCentroids {
                    let sim = cosineSimilarity(centroid, uc)
                    if sim >= bestSim {
                        bestSim = sim
                        bestID = uid
                    }
                }
                if let bestID {
                    // Don't overwrite the centroid — keep the first one we
                    // bound to this slot as the canonical reference. Averaging
                    // sounds tempting but mic-vs-system embeddings differ
                    // enough that the average can drift toward neither.
                    return bestID
                }
            }
            // No match — fresh slot.
            let nextIndex = orderedIDs.filter { $0 != "me" }.count + 1
            let newID = "speaker_\(nextIndex)"
            orderedIDs.append(newID)
            if let centroid { unifiedCentroids[newID] = centroid }
            return newID
        }

        // Step 2: remaining mic clusters, ordered by total speech time so
        // the more-active people get the lower speaker_N numbers.
        if let micDiar {
            let micTotals = Dictionary(grouping: micDiar.segments, by: { $0.speakerLabel })
                .mapValues { $0.reduce(0.0) { $0 + ($1.end - $1.start) } }
            let sortedClusters = micTotals.keys.sorted {
                (micTotals[$0] ?? 0) > (micTotals[$1] ?? 0)
            }
            for label in sortedClusters where label != meCluster {
                let centroid = micDiar.clusterCentroids[label]
                let uid = register(label: label, centroid: centroid)
                micMapping[label] = uid
            }
        }

        // Step 3: system clusters in order of total speech time. Each one
        // either matches an existing unified slot via centroid similarity
        // (so the system track recognises a person already attributed to
        // the mic) or becomes a fresh speaker_N.
        if let systemDiar {
            let sysTotals = Dictionary(grouping: systemDiar.segments, by: { $0.speakerLabel })
                .mapValues { $0.reduce(0.0) { $0 + ($1.end - $1.start) } }
            let sortedClusters = sysTotals.keys.sorted {
                (sysTotals[$0] ?? 0) > (sysTotals[$1] ?? 0)
            }
            for label in sortedClusters {
                let centroid = systemDiar.clusterCentroids[label]
                let uid = register(label: label, centroid: centroid)
                systemMapping[label] = uid
            }
        }

        return UnifiedSpeakerSpace(
            micMapping: micMapping,
            systemMapping: systemMapping,
            discoveredOrder: orderedIDs
        )
    }

    /// Cosine similarity between two equal-length float vectors. FluidAudio
    /// emits unit-normalised speaker embeddings, so the inner product alone
    /// would be enough — we divide by the norms anyway for robustness in
    /// case a future model version stops normalising.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Walk the merged, time-ordered word timeline and emit the speaker IDs
    /// that actually appear in the transcript, in first-occurrence order.
    /// Anything `unifySpeakerSpace` allocated that didn't survive (because all
    /// its words got dedup'd or folded, or its cluster produced zero words) is
    /// excluded — the chip row should reflect reality, not the diarizer's intent.
    /// `words` must already be sorted by start time.
    nonisolated static func discoveredSpeakerIDsInOrder(
        words: [SpeakerAttributedWord]
    ) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        for w in words where !seen.contains(w.speakerId) {
            seen.insert(w.speakerId)
            order.append(w.speakerId)
        }
        return order
    }

    // MARK: - Trivial-speaker fold

    /// A speaker with at most this many surviving words AND no more than
    /// `trivialSpeakerMaxSeconds` of total speech is treated as a phantom and
    /// folded into the nearest real speaker. Two words is deliberately tight:
    /// it catches a single stray bleed word that seeded a "Me" chip, or a ~2 s
    /// diarizer blip cluster, while leaving a genuine brief interjection
    /// ("yeah, makes sense" — three words) untouched.
    private nonisolated static let trivialSpeakerMaxWords = 2
    private nonisolated static let trivialSpeakerMaxSeconds: Double = 2.0

    /// Re-attribute the words of phantom speakers to the temporally-nearest
    /// surviving (non-trivial) speaker, so a spurious one- or two-word cluster
    /// doesn't surface as its own chip. The words themselves are kept — only
    /// their `speakerId` changes — so no transcript content is lost; the stray
    /// token just joins the adjacent turn it almost certainly belonged to.
    ///
    /// No-ops unless there is at least one non-trivial speaker to fold into
    /// (so a recording that is genuinely just a few words under one speaker is
    /// left exactly as-is). `words` must be sorted by start time; the result
    /// preserves that order.
    nonisolated static func foldTrivialSpeakers(
        words: [SpeakerAttributedWord]
    ) -> [SpeakerAttributedWord] {
        guard words.count > 1 else { return words }

        // Per-speaker word count + total duration across the whole timeline.
        var wordCount: [String: Int] = [:]
        var duration: [String: Double] = [:]
        for w in words {
            wordCount[w.speakerId, default: 0] += 1
            duration[w.speakerId, default: 0] += max(0, w.end - w.start)
        }

        let trivial = Set(wordCount.keys.filter { id in
            (wordCount[id] ?? 0) <= trivialSpeakerMaxWords
                && (duration[id] ?? 0) <= trivialSpeakerMaxSeconds
        })
        guard !trivial.isEmpty else { return words }

        // Need a real speaker to fold into; if every speaker is trivial (e.g. a
        // recording that is just two stray words) leave the timeline untouched.
        let survivors = words.filter { !trivial.contains($0.speakerId) }
        guard !survivors.isEmpty else { return words }

        return words.map { w in
            guard trivial.contains(w.speakerId) else { return w }
            let mid = (w.start + w.end) / 2
            // Nearest surviving word in time wins the re-attribution.
            var bestID = survivors[0].speakerId
            var bestDist = Double.infinity
            for s in survivors {
                let sMid = (s.start + s.end) / 2
                let d = abs(sMid - mid)
                if d < bestDist { bestDist = d; bestID = s.speakerId }
            }
            return SpeakerAttributedWord(start: w.start, end: w.end, text: w.text, speakerId: bestID)
        }
    }

    // MARK: - Mic-echo dedup

    /// Drop mic words that look like echoes of system words. For each mic
    /// word, scans the system track for a word starting within ±300 ms whose
    /// normalised text is identical (or within a small Levenshtein distance —
    /// ASR variance — keyed to token length). Each system word is consumed at
    /// most once so a single loud word on the system track can't wipe a run
    /// of repeated mic words.
    ///
    /// The comparison is symmetric in the sense that words said by the user
    /// AND echoed by the remote speaker get dropped from the mic side — the
    /// system track is the canonical source for any echo. That's intentional;
    /// the alternative (drop the system side) would put "Me" in the transcript
    /// reading lines they actually heard rather than said.
    nonisolated static func dedupeMicEchoes(
        micWords: [SpeakerAttributedWord],
        systemWords: [SpeakerAttributedWord]
    ) -> [SpeakerAttributedWord] {
        guard !micWords.isEmpty, !systemWords.isEmpty else { return micWords }

        // ±300 ms window. Tuned in the report — wide enough to absorb
        // Bluetooth round-trip plus diarizer drift, narrow enough that two
        // genuinely-different "yeah"s a sentence apart don't collide.
        let windowSeconds: Double = 0.3

        // Pre-normalise the system side once. We index by original position
        // so the "already matched" set stays well-defined.
        let normalisedSystem: [(idx: Int, start: Double, text: String)] =
            systemWords.enumerated().map { (idx, w) in
                (idx, w.start, normaliseForCompare(w.text))
            }

        // For each mic word, scan the system track. The system track is
        // sorted by start time after the merge upstream but we don't rely on
        // that here — meetings rarely have more than a few thousand words and
        // a linear pass is comfortably fast. If profiling shows this matters,
        // swap to a binary search over `start`.
        var matchedSystemIdx = Set<Int>()
        var kept: [SpeakerAttributedWord] = []
        kept.reserveCapacity(micWords.count)

        for mic in micWords {
            let micNorm = normaliseForCompare(mic.text)
            // Skip empty normalisations — punctuation-only tokens can never
            // be an echo, keep them on the mic side.
            if micNorm.isEmpty {
                kept.append(mic)
                continue
            }

            var matchIdx: Int?
            for entry in normalisedSystem {
                if matchedSystemIdx.contains(entry.idx) { continue }
                if abs(entry.start - mic.start) > windowSeconds { continue }
                if entry.text.isEmpty { continue }
                if entry.text == micNorm {
                    matchIdx = entry.idx
                    break
                }
                // Loose match: small ASR variance ("yeah" vs "yeh", "okay"
                // vs "ok"). Distance threshold scales with token length so
                // we don't collapse genuinely different short words.
                let maxDist = entry.text.count <= 3 && micNorm.count <= 3 ? 1 : 2
                if levenshtein(entry.text, micNorm) <= maxDist {
                    matchIdx = entry.idx
                    break
                }
            }

            if let matchIdx {
                matchedSystemIdx.insert(matchIdx)
                // Drop the mic word — its system-track counterpart survives
                // unchanged and represents this utterance in the transcript.
            } else {
                kept.append(mic)
            }
        }

        return kept
    }

    /// Lowercase, strip everything that isn't a letter or digit, collapse
    /// whitespace. Used only for echo comparison — the surviving word's
    /// `text` field keeps its original casing and punctuation.
    private nonisolated static func normaliseForCompare(_ s: String) -> String {
        let lower = s.lowercased()
        let scalars = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Standard two-row Levenshtein. Both arguments should already be
    /// normalised (`normaliseForCompare`) — we don't lowercase or strip here.
    /// Returns the edit distance between the two strings.
    nonisolated static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var prev = Array(0...bChars.count)
        var curr = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,         // insertion
                    prev[j] + 1,             // deletion
                    prev[j - 1] + cost       // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bChars.count]
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

    /// Build the speaker chip palette for a meeting. `speakerIDs` is the
    /// encounter-ordered list from the merged transcript ("me" if mic words
    /// survived, then "speaker_2", "speaker_3", … or "other" for the
    /// diarizer-failed fallback path).
    ///
    /// The "me" chip always gets the brand blue; everyone else cycles
    /// through `speakerPalette` in encounter order so colours are stable
    /// across reprocesses of the same meeting (same encounter order, same
    /// palette index → same colour).
    nonisolated static func buildSpeakerPalette(
        speakerIDs: [String]
    ) -> [MeetingMeta.Speaker] {
        var speakers: [MeetingMeta.Speaker] = []
        // Track palette index for non-me, non-other entries so colours
        // stay stable regardless of where "me" appears in the order.
        var paletteIndex = 0
        for id in speakerIDs {
            switch id {
            case "me":
                speakers.append(.init(id: "me", displayName: "Me", colorHex: "#5B9BD5", isMe: true))
            case "other":
                // v0.2 compatibility — diarizer-failed transcripts keep
                // the original orange.
                speakers.append(.init(id: "other", displayName: "Other", colorHex: "#ED7D31", isMe: false))
            default:
                // "speaker_N". Display number tracks the encounter slot —
                // the first speaker_* in the order is "Speaker 1", the
                // second is "Speaker 2", and so on. Note that the internal
                // ID's number (set in unifySpeakerSpace) won't necessarily
                // match the display number — that's fine; rename UI uses
                // displayName, not the internal id.
                let displayIndex = speakers.filter { $0.id.hasPrefix("speaker_") }.count + 1
                let color = speakerPalette[paletteIndex % speakerPalette.count]
                paletteIndex += 1
                speakers.append(.init(id: id, displayName: "Speaker \(displayIndex)", colorHex: color, isMe: false))
            }
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
