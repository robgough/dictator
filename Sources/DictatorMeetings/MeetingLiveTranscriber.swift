import Foundation
@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Observation

/// Drives a live, draft transcript while a meeting is being recorded. Sits
/// alongside the two recorders (system-audio process tap + mic
/// AVCaptureSession) and consumes both their sample streams as they arrive,
/// runs them through Parakeet in chunks larger than dictation uses, and
/// exposes a continuously-growing `interimText` the Meetings detail view
/// reads plus a structured `transcriptLines` the live-notes accumulator
/// consumes.
///
/// The canonical, diarized transcript is still produced by `MeetingProcessor`
/// after the user stops the recording — this is purely a "watch the meeting
/// take shape" affordance. Errors here are non-fatal: a failed chunk gets
/// logged + dropped, the recording keeps running, and the post-pass
/// transcript is unaffected.
///
/// **Track strategy:** both sides. Mic samples are tagged "Me", system
/// samples "Them". A single serial Parakeet queue handles both — we never run
/// two inferences at once, so there's no ANE contention and no second model
/// load. The labels are coarse (mic-vs-system, not per-person diarization);
/// the post-pass diarizer still produces the fine-grained speaker split in
/// the final transcript. Mic windows that are really speaker bleed of the
/// remote audio (you're only *listening* to remote voices) are dropped rather
/// than mislabelled as "Me" — the system track already carries that speech.
///
/// **Chunking:** non-overlapping 8-second windows per source. Each window runs
/// through `MeetingParakeetServiceHolder.shared` — a meeting-dedicated ASR
/// pipeline that *shares the dictation service's loaded weights* (FluidAudio's
/// `AsrModels` is a value of model references, so a second `AsrManager` over it
/// is cheap) but runs on its own serial actor. That isolation is deliberate: a
/// long post-pass (or this live stream) can no longer block a dictation that
/// the user fires mid- or post-meeting. The post-capture processor reaches for
/// the same meeting holder moments later, so the model stays warm across the
/// boundary instead of being thrashed. Non-overlapping windows mean a word that
/// straddles the boundary may get cut — we accept that for the draft view; the
/// post-pass transcript is the authoritative one.
@MainActor
@Observable
final class MeetingLiveTranscriber {
    /// One labelled line of live transcript. `speaker` is the coarse source
    /// label ("Me" / "Them"); the accumulator feeds these to the LLM.
    struct LiveLine: Sendable, Equatable {
        let speaker: String
        let text: String
    }

    static let meLabel = "Me"
    static let themLabel = "Them"

    /// The growing draft transcript, rendered with `Me:` / `Them:` labels.
    /// SETTLED text only — the post-context re-transcription. The notes
    /// accumulator and mirror derive from this (via `transcriptLines`).
    private(set) var interimText: String = ""

    /// What the live pane actually renders: settled text plus the
    /// PROVISIONAL tail — each utterance first-pass transcribed the moment
    /// its pause lands, shown immediately, then visibly replaced when its
    /// settled version commits (the typewriter view animates the revision).
    /// Without this, a phrase stayed invisible until `holdback` more
    /// utterances piled up behind it — tens of seconds on a chatty track.
    /// Display-only: nothing downstream consumes provisional text.
    private(set) var liveDisplayText: String = ""

    /// Structured form of the same draft — read by `MeetingNotesAccumulator`
    /// on its own cadence. Not observed (the notes pane renders the LLM output,
    /// not this), so it doesn't churn the UI.
    @ObservationIgnored private(set) var transcriptLines: [LiveLine] = []

    /// True while the transcriber is live (between init and `stop()`).
    /// Observed by the UI to choose the "Listening…" placeholder vs. text.
    private(set) var isRunning: Bool = false

    /// Fired on the main actor whenever a committed line is appended to
    /// `transcriptLines`, so an observer can mirror the live transcript to disk.
    /// I/O-free here by design — the callback owns any persistence.
    @ObservationIgnored var onTranscriptUpdated: (() -> Void)?

    private let parakeetModelID: String

    /// 16 kHz mono samples not yet flushed into a chunk, one buffer per source.
    @ObservationIgnored private var micBuffer: [Float] = []
    @ObservationIgnored private var systemBuffer: [Float] = []

    /// Trailing audio of the last *committed* utterance per source, prepended
    /// as context when settling the next.
    @ObservationIgnored private var micContext: [Float] = []
    @ObservationIgnored private var systemContext: [Float] = []

    /// One segmented-but-not-yet-settled utterance: its audio, a sequence
    /// number for cross-source display ordering, and the provisional text
    /// once its first-pass transcription lands (nil = in flight or skipped).
    struct PendingUtterance {
        let id = UUID()
        let seq: Int
        let samples: [Float]
        var provisional: String?
    }

    /// Segmented-but-not-yet-committed utterances per source. We hold the
    /// most recent few back and only commit the oldest once enough have piled
    /// up behind it — re-transcribing it together with the following speech so
    /// a continued thought isn't punctuated as a finished sentence. Only
    /// committed lines reach the transcript and the notes; the provisional
    /// texts reach the display only.
    @ObservationIgnored private var pendingMic: [PendingUtterance] = []
    @ObservationIgnored private var pendingSystem: [PendingUtterance] = []
    @ObservationIgnored private var utteranceSeq = 0

    /// Cached resamplers — one per source, each confined to the thread that
    /// feeds it (system on the main actor, mic on the capture queue) so they
    /// never touch the same converter concurrently. Reusing them means the
    /// live path doesn't allocate a fresh AVAudioConverter for every ~10 ms
    /// buffer across an hours-long meeting.
    private let systemResampler = MonoResampler(targetRate: 16_000)
    nonisolated(unsafe) private let micResampler = MonoResampler(targetRate: 16_000)

    /// True while `finishPending()` is draining the held-back utterances on
    /// stop — suppresses the normal scheduler so it doesn't fight the drain.
    @ObservationIgnored private var finishing = false

    /// Task running the current chunk transcribe, if any. Cancelled on
    /// `stop()` so the in-flight inference doesn't outlive the meeting.
    @ObservationIgnored private var inflightTask: Task<Void, Never>?

    /// Label of the last line appended, so consecutive same-source chunks
    /// merge onto one line instead of restarting the prefix each window.
    @ObservationIgnored private var lastSpeaker: String?

    // MARK: Voice-activity chunking
    //
    // Rather than slice fixed 8 s windows (which cut mid-word and hand Parakeet
    // half-utterances), we wait for a natural pause and flush one complete
    // utterance at a time. A complete phrase is what Parakeet transcribes best,
    // and pause boundaries are also where the live notes most naturally update.

    /// Analysis frame for the energy/VAD scan. 320 samples = 20 ms at 16 kHz.
    private static let frameSamples = 320

    /// RMS at/above which a frame counts as speech (not silence). Above the
    /// `silenceRMS` floor so room tone doesn't read as voice.
    private static let vadRMS: Float = 0.01

    /// A pause this long (in frames) after speech ends an utterance → flush.
    /// 30 frames ≈ 0.6 s — long enough that a mid-sentence breath (which is
    /// usually < 0.5 s) doesn't get treated as the end of a thought and
    /// punctuated like one, while still keeping the transcript responsive.
    private static let pauseFrames = 30

    /// How much of the previous utterance's audio (per source) to prepend as
    /// context when transcribing the next one. Giving Parakeet the run-up
    /// means a continued thought isn't transcribed as a fresh standalone
    /// sentence; we keep only the newly-spoken words (by timestamp). ~2.5 s.
    private static let maxContextSamples = Int(2.5 * 16_000)

    /// Keep this much audio before speech onset so we never clip the first
    /// phoneme, and this much after speech ends so trailing consonants survive.
    private static let prerollFrames = 8   // ≈ 160 ms
    private static let tailFrames = 6      // ≈ 120 ms

    /// Force a cut after this long with no pause (someone monologuing) so a
    /// single long turn still streams instead of buffering forever.
    private static let maxChunkSamples = 22 * 16_000

    /// Keep this many freshly-segmented utterances pending (uncommitted) per
    /// source, so each can be re-transcribed with the speech that follows
    /// before it's committed — fixing fragments that were cut at a mid-thought
    /// pause and would otherwise read as finished sentences.
    private static let holdback = 2
    /// How many following utterances to fold in as context when settling one.
    private static let lookahead = 1

    /// Hard cap on buffered-but-unsettled utterances per source. If ASR can't
    /// keep up with the conversation (busy ANE, thermal throttle, the live
    /// notes LLM contending), the backlog would otherwise grow without bound
    /// for the whole meeting — holding raw utterance audio and deepening the
    /// settle queue, which is a core driver of the in-call slowdown. When we
    /// exceed this we drop the oldest pending utterance: the live draft loses a
    /// little speech under sustained overload rather than ballooning. The draft
    /// is explicitly non-authoritative — the post-pass transcript is canonical.
    private static let maxPending = 8

    /// Cap on the rendered live transcript. The pane lays out the whole
    /// `interimText` string as one `Text` on each committed utterance, so an
    /// unbounded string makes layout cost climb with meeting length. We keep
    /// only a trailing window for display; the authoritative full transcript is
    /// rebuilt from disk by the post-pass regardless. Trimming runs per
    /// committed utterance (a low frequency), so its O(n) cost is irrelevant
    /// next to the per-update layout it saves.
    private static let maxInterimChars = 12_000
    private static let interimKeepChars = 8_000

    /// Don't bother running ASR on anything shorter than this; FluidAudio's
    /// AsrManager hard-rejects sub-0.3 s inputs as `.invalidAudioData`. We
    /// pad the floor up to 0.4 s to stay clear of that edge.
    private static let minChunkSamples: Int = Int(0.4 * 16_000)

    /// RMS floor below which a chunk is treated as silence and skipped — saves
    /// ANE cycles on dead air (especially the system track between remote
    /// utterances) and avoids Parakeet hallucinating tokens from near-silence.
    /// ~-48 dBFS; comfortably below conversational speech.
    private static let silenceRMS: Float = 0.004

    /// Below this concurrent system level the remote side is essentially quiet,
    /// so a hot mic is the user genuinely speaking — never treated as bleed.
    private static let bleedSystemFloor: Float = 0.012

    /// A mic window quieter than this fraction of the concurrent system level
    /// is treated as speaker bleed (and dropped) rather than the user. Bleed
    /// lands at ~0.1–0.3× the remote audio's direct level; near-field speech
    /// at ~1× or above — so 0.5× cleanly separates the two without dropping
    /// the user talking over the call.
    private static let bleedFraction: Float = 0.5

    /// `modelID` is captured here so the transcriber never reaches into
    /// settings — keeps the dependency explicit and matches the way the
    /// processor is given the model id by the session.
    init(parakeetModelID: String) {
        self.parakeetModelID = parakeetModelID
        self.isRunning = true
    }

    /// Receive mono Float32 mic audio (at the device's native rate) from
    /// `MeetingMicRecorder`. Called from the off-main capture queue — we
    /// resample to 16 kHz here, then hop to the main actor to touch the chunk
    /// state, since `[Float]` mutation and `Task` launch both belong on a
    /// single actor for this class.
    nonisolated func feedMicSamples(_ mono: [Float], sampleRate: Double) {
        guard sampleRate > 0, !mono.isEmpty else { return }
        guard let samples = micResampler.resample(mono, from: sampleRate) else { return }
        Task { @MainActor [weak self] in
            self?.append(samples: samples, to: .mic)
        }
    }

    /// Receive mono Float32 system audio (the remote side of the call) from
    /// `MeetingAudioRecorder`. Already main-actor (the recorder fires
    /// `onSystemSamples` from its `write`), but we resample off the hot path
    /// is unnecessary here — the buffers are small. Resample to 16 kHz and
    /// append to the system buffer.
    func feedSystemSamples(_ mono: [Float], sampleRate: Double) {
        guard sampleRate > 0, !mono.isEmpty else { return }
        guard let samples = systemResampler.resample(mono, from: sampleRate) else { return }
        append(samples: samples, to: .system)
    }

    /// Cleanly stop the live transcriber. Cancels the in-flight chunk task and
    /// drops the pending buffers. The Parakeet weights live in
    /// `MeetingParakeetServiceHolder.shared` and are shared with `MeetingProcessor`,
    /// which starts its post-capture pass on this same warm model microseconds
    /// after this returns — so we deliberately *don't* unload the holder here.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        inflightTask?.cancel()
        inflightTask = nil
        micBuffer.removeAll(keepingCapacity: false)
        systemBuffer.removeAll(keepingCapacity: false)
        micContext.removeAll(keepingCapacity: false)
        systemContext.removeAll(keepingCapacity: false)
        pendingMic.removeAll(keepingCapacity: false)
        pendingSystem.removeAll(keepingCapacity: false)
        rebuildDisplay()
    }

    // MARK: - Main-actor state

    private enum Source { case mic, system }

    private func append(samples: [Float], to source: Source) {
        guard isRunning, !samples.isEmpty else { return }
        switch source {
        case .mic:    micBuffer.append(contentsOf: samples)
        case .system: systemBuffer.append(contentsOf: samples)
        }
        scheduleChunkIfReady()
    }

    /// Pull every ready utterance out of the audio buffers and queue it as
    /// pending, then settle the oldest if enough have piled up behind it. Loops
    /// so consuming stale silence or a dropped bleed window doesn't stall.
    private func scheduleChunkIfReady() {
        guard isRunning else { return }

        while true {
            if let (chunk, consume) = Self.voiceChunk(micBuffer) {
                micBuffer.removeFirst(consume)
                if chunk.isEmpty { continue }
                // Drop mic utterances that are really speaker bleed of the
                // remote audio (you're only listening) rather than mislabelling
                // them as "Me" — the system track already carries that speech.
                if Self.isLikelyBleed(mic: chunk, systemBuffer: systemBuffer) { continue }
                enqueue(chunk, on: .mic)
                continue
            }
            if let (chunk, consume) = Self.voiceChunk(systemBuffer) {
                systemBuffer.removeFirst(consume)
                if chunk.isEmpty { continue }
                enqueue(chunk, on: .system)
                continue
            }
            break
        }
        settleIfReady()
    }

    /// Queue a freshly segmented utterance and kick its provisional
    /// transcription so the display shows it within a beat of the pause —
    /// unless the queue is already backed up (thermal, contention), in which
    /// case the provisional pass is skipped and the display simply waits for
    /// the settle, i.e. degrades to the old behaviour.
    private func enqueue(_ chunk: [Float], on source: Source) {
        utteranceSeq += 1
        let utterance = PendingUtterance(seq: utteranceSeq, samples: chunk, provisional: nil)
        switch source {
        case .mic:
            pendingMic.append(utterance)
            if pendingMic.count > Self.maxPending {
                pendingMic.removeFirst(pendingMic.count - Self.maxPending)
            }
        case .system:
            pendingSystem.append(utterance)
            if pendingSystem.count > Self.maxPending {
                pendingSystem.removeFirst(pendingSystem.count - Self.maxPending)
            }
        }
        let backlog = (source == .mic ? pendingMic : pendingSystem).count
        guard backlog <= Self.holdback + 2, !finishing else { return }
        startProvisional(for: utterance, source: source)
    }

    /// First-pass transcribe one utterance for display. Serialised through
    /// the same meeting ASR actor as the settle passes; an utterance that
    /// settles before its provisional lands just discards the result.
    private func startProvisional(for utterance: PendingUtterance, source: Source) {
        let samples = utterance.samples
        let id = utterance.id
        let modelID = parakeetModelID
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            let text = (try? await MeetingParakeetServiceHolder.shared.transcribe(
                samples: samples, modelID: modelID
            )) ?? ""
            guard self.isRunning else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch source {
            case .mic:
                guard let idx = self.pendingMic.firstIndex(where: { $0.id == id }) else { return }
                self.pendingMic[idx].provisional = trimmed
            case .system:
                guard let idx = self.pendingSystem.firstIndex(where: { $0.id == id }) else { return }
                self.pendingSystem[idx].provisional = trimmed
            }
            self.rebuildDisplay()
        }
    }

    /// Commit the oldest pending utterance once `holdback` more sit behind it,
    /// re-transcribing it together with the following audio (and the previous
    /// committed tail) so its punctuation reflects the continuation rather than
    /// treating a mid-thought pause as the end of a sentence.
    private func settleIfReady() {
        guard isRunning, !finishing, inflightTask == nil else { return }

        let source: Source
        if pendingMic.count > Self.holdback { source = .mic }
        else if pendingSystem.count > Self.holdback { source = .system }
        else { return }

        inflightTask = Task { @MainActor [weak self] in
            await self?.settle(source: source)
        }
    }

    private func settle(source: Source) async {
        defer { inflightTask = nil }
        guard isRunning else { return }
        await settleOne(source: source)
        if !finishing { scheduleChunkIfReady() }
    }

    /// Re-transcribe and commit the oldest pending utterance for `source`,
    /// folding in the previous committed tail and the following utterance so
    /// its punctuation reflects the surrounding speech.
    private func settleOne(source: Source) async {
        let pending = source == .mic ? pendingMic : pendingSystem
        guard let oldest = pending.first else { return }
        let following = pending[1...].prefix(Self.lookahead).reduce(into: [Float]()) { $0 += $1.samples }
        let prevContext = source == .mic ? micContext : systemContext
        let speaker = source == .mic ? Self.meLabel : Self.themLabel

        let text = (try? await transcribeSettling(oldest: oldest.samples, following: following, prevContext: prevContext)) ?? ""
        guard !Task.isCancelled else { return }
        if source == .mic {
            if !pendingMic.isEmpty { pendingMic.removeFirst() }
            micContext = Array(oldest.samples.suffix(Self.maxContextSamples))
        } else {
            if !pendingSystem.isEmpty { pendingSystem.removeFirst() }
            systemContext = Array(oldest.samples.suffix(Self.maxContextSamples))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            appendLine(speaker: speaker, text: trimmed)
        } else {
            // Nothing committed, but the settled utterance's provisional
            // line (if any) must leave the display.
            rebuildDisplay()
        }
    }

    /// Settle and commit every held-back utterance, so stopping a recording
    /// doesn't drop the last couple of phrases from the live transcript and
    /// live notes. Call (and await) this before `stop()`.
    func finishPending() async {
        guard isRunning else { return }
        finishing = true
        await inflightTask?.value
        inflightTask = nil
        // Let any in-flight sample-forwarding tasks land, then force the
        // trailing buffer (speech after the last pause, which never triggered a
        // cut) into pending so the very last words aren't lost.
        try? await Task.sleep(for: .milliseconds(60))
        if micBuffer.count >= Self.minChunkSamples {
            utteranceSeq += 1
            pendingMic.append(PendingUtterance(seq: utteranceSeq, samples: micBuffer, provisional: nil))
        }
        micBuffer.removeAll(keepingCapacity: false)
        if systemBuffer.count >= Self.minChunkSamples {
            utteranceSeq += 1
            pendingSystem.append(PendingUtterance(seq: utteranceSeq, samples: systemBuffer, provisional: nil))
        }
        systemBuffer.removeAll(keepingCapacity: false)
        while isRunning, !(pendingMic.isEmpty && pendingSystem.isEmpty) {
            if !pendingMic.isEmpty { await settleOne(source: .mic) }
            if !pendingSystem.isEmpty { await settleOne(source: .system) }
        }
    }

    /// Transcribe `[prevContext + oldest + following]` and keep only the words
    /// that fall in the oldest utterance's own time range — so it's recognised
    /// and punctuated with both the previous and the following speech in view.
    private func transcribeSettling(oldest: [Float], following: [Float], prevContext: [Float]) async throws -> String {
        if prevContext.isEmpty, following.isEmpty {
            return try await MeetingParakeetServiceHolder.shared.transcribe(samples: oldest, modelID: parakeetModelID)
        }
        let combined = prevContext + oldest + following
        let prevDur = Double(prevContext.count) / 16_000
        let oldestDur = Double(oldest.count) / 16_000
        let words = try await MeetingParakeetServiceHolder.shared.transcribeWithTimestamps(
            samples: combined, modelID: parakeetModelID
        )
        guard !words.isEmpty else {
            return try await MeetingParakeetServiceHolder.shared.transcribe(samples: oldest, modelID: parakeetModelID)
        }
        let lo = prevDur - 0.05
        let hi = prevDur + oldestDur + 0.05
        return words.filter { $0.start >= lo && $0.start < hi }.map(\.text).joined(separator: " ")
    }

    /// Find a complete utterance at the front of `buf`: trim leading silence,
    /// then return the speech up to the next pause (plus a small pre-roll/tail)
    /// and the number of samples to consume (speech + the detected pause).
    /// Returns nil while speech is still ongoing and no pause has appeared yet.
    /// An empty chunk with a positive consume means "only stale silence here —
    /// drop it."
    private static func voiceChunk(_ buf: [Float]) -> (chunk: [Float], consume: Int)? {
        let n = buf.count
        let frameCount = n / frameSamples
        guard frameCount >= 1 else { return nil }

        // Voiced flag per frame.
        var voiced = [Bool](repeating: false, count: frameCount)
        for f in 0..<frameCount {
            voiced[f] = frameRMS(buf, at: f * frameSamples) >= vadRMS
        }

        guard let firstVoiced = voiced.firstIndex(of: true) else {
            // All silence so far. Drop everything but a short tail so the
            // buffer doesn't grow unbounded during quiet stretches.
            let keep = prerollFrames * frameSamples
            return n > keep ? ([], n - keep) : nil
        }

        let startSample = max(0, (firstVoiced - prerollFrames) * frameSamples)

        // Walk forward looking for a pause (pauseFrames consecutive unvoiced).
        var lastVoiced = firstVoiced
        var silenceRun = 0
        for f in firstVoiced..<frameCount {
            if voiced[f] {
                lastVoiced = f
                silenceRun = 0
            } else {
                silenceRun += 1
                if silenceRun >= pauseFrames {
                    let endSample = min(n, (lastVoiced + 1 + tailFrames) * frameSamples)
                    let consume = min(n, (f + 1) * frameSamples)
                    if endSample - startSample >= minChunkSamples {
                        return (Array(buf[startSample..<endSample]), consume)
                    }
                    // Too short to be real speech — drop through the pause.
                    return ([], consume)
                }
            }
        }

        // No pause yet. Force a cut if a single turn has run on too long.
        if n >= maxChunkSamples {
            let endSample = maxChunkSamples
            if endSample - startSample >= minChunkSamples {
                return (Array(buf[startSample..<endSample]), endSample)
            }
            return ([], endSample)
        }
        return nil
    }

    private static func frameRMS(_ buf: [Float], at start: Int) -> Float {
        let end = min(start + frameSamples, buf.count)
        guard end > start else { return 0 }
        var ms: Float = 0
        buf.withUnsafeBufferPointer { ptr in
            vDSP_measqv(ptr.baseAddress! + start, 1, &ms, vDSP_Length(end - start))
        }
        return ms.squareRoot()
    }

    /// Append a transcribed window to both the structured lines and the
    /// rendered `interimText`. Consecutive windows from the same source merge
    /// onto one line; a source change starts a fresh `Label: …` line.
    private func appendLine(speaker: String, text: String) {
        // Deterministic vocabulary pass — same dictionary dictation uses, so
        // names/jargon land correctly in the live transcript (and the live
        // notes built from it).
        let entries = VocabularyStore.shared.entries
        let line = entries.isEmpty ? text : Vocabulary.apply(entries, to: text)
        transcriptLines.append(LiveLine(speaker: speaker, text: line))
        if interimText.isEmpty {
            interimText = "\(speaker): \(line)"
        } else if speaker == lastSpeaker {
            interimText.append(" " + line)
        } else {
            interimText.append("\n\(speaker): \(line)")
        }
        lastSpeaker = speaker
        trimInterimIfNeeded()
        rebuildDisplay()
        onTranscriptUpdated?()
    }

    /// Compose what the pane renders: the settled transcript plus the
    /// provisional tail (both sources, in arrival order). The typewriter
    /// view diffs successive values, so a provisional line being replaced
    /// by its settled version animates as a visible revision.
    private func rebuildDisplay() {
        var text = interimText
        let provisionals = (pendingMic.map { ($0.seq, Self.meLabel, $0.provisional) }
            + pendingSystem.map { ($0.seq, Self.themLabel, $0.provisional) })
            .sorted { $0.0 < $1.0 }
        for (_, speaker, provisional) in provisionals {
            guard let provisional, !provisional.isEmpty else { continue }
            text += text.isEmpty ? "\(speaker): \(provisional)" : "\n\(speaker): \(provisional)"
        }
        if liveDisplayText != text { liveDisplayText = text }
    }

    /// Keep `interimText` to a trailing window so the live pane never lays out
    /// an ever-growing string. Cuts on a line boundary and marks the elision so
    /// the reader can tell earlier lines scrolled off (they're still in the
    /// authoritative post-pass transcript).
    private func trimInterimIfNeeded() {
        guard interimText.count > Self.maxInterimChars else { return }
        let dropCount = interimText.count - Self.interimKeepChars
        let cut = interimText.index(interimText.startIndex, offsetBy: dropCount)
        if let newline = interimText[cut...].firstIndex(of: "\n") {
            interimText = "…" + String(interimText[newline...])
        } else {
            interimText = "…\n" + String(interimText[cut...])
        }
    }


    /// True when a mic window looks like speaker bleed of the concurrent
    /// system audio rather than the user actually speaking. Compares the mic
    /// window's energy to the front of the system buffer (roughly the same
    /// wall-clock window, since we've only consumed from the mic side). When
    /// the remote side is essentially silent, a hot mic is the user, never
    /// bleed.
    private static func isLikelyBleed(mic: [Float], systemBuffer: [Float]) -> Bool {
        let n = min(mic.count, systemBuffer.count)
        guard n >= minChunkSamples else { return false }
        let sysRMS = rms(systemBuffer, count: n)
        guard sysRMS > bleedSystemFloor else { return false }
        // Acoustic bleed from speakers into the mic is attenuated well below
        // the remote audio's direct level; near-field user speech sits at
        // roughly the same level or louder. So a mic window much quieter than
        // the concurrent system audio is almost certainly bleed.
        return rms(mic) < bleedFraction * sysRMS
    }

    /// RMS over the first `count` samples (the whole array when `count` is nil).
    private static func rms(_ samples: [Float], count: Int? = nil) -> Float {
        let n = min(count ?? samples.count, samples.count)
        guard n > 0 else { return 0 }
        var ms: Float = 0
        samples.withUnsafeBufferPointer { ptr in
            vDSP_measqv(ptr.baseAddress!, 1, &ms, vDSP_Length(n))
        }
        return ms.squareRoot()
    }
}
