import Foundation
import Observation
import AppKit

enum PipelineState: Equatable {
    case idle
    case capturingSelection
    /// AVAudioEngine has been asked to start but hasn't begun producing
    /// buffers yet. On wired mics this flashes by in milliseconds; on
    /// Bluetooth (AirPods etc.) it can last 2–5 s while macOS negotiates
    /// HFP. Surfaced in the HUD so the user understands they're not yet
    /// being recorded.
    case warmingUp(isAssistant: Bool)
    case recording(level: Float, isAssistant: Bool)
    case transcribing
    case formatting
    case fixingGrammar
    case restructuring
    case assisting
    case compacting
    case done(text: String, pasted: Bool, note: String?)
    case failed(String)

    var iconName: String {
        switch self {
        case .idle: "waveform"
        case .capturingSelection: "selection.pin.in.out"
        case .warmingUp: "antenna.radiowaves.left.and.right"
        case .recording: "waveform.badge.mic"
        case .transcribing: "waveform.badge.magnifyingglass"
        case .formatting: "sparkles"
        case .fixingGrammar: "text.badge.checkmark"
        case .restructuring: "list.bullet.indent"
        case .assisting: "wand.and.stars"
        case .compacting: "archivebox"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        }
    }

    var isActive: Bool {
        if case .idle = self { return false }
        if case .done = self { return false }
        if case .failed = self { return false }
        return true
    }

    /// Whether the user can usefully abort what's happening. True while the
    /// pipeline is doing something interruptible (recording or any thinking
    /// state); false in idle / done-linger / failed where there's nothing to
    /// stop. Drives both the HUD's hover-cancel button and the panel's
    /// `ignoresMouseEvents` so click-through works during done-linger.
    var canCancel: Bool {
        switch self {
        case .idle, .done, .failed: false
        default: true
        }
    }
}

@MainActor
@Observable
final class Pipeline {
    private(set) var state: PipelineState = .idle
    private(set) var lastResult: String = ""

    /// Mode driving the in-flight dictation. Captured at `startRecording()`
    /// time from `settings.activeMode(forFrontmostBundleID:)`, then frozen
    /// for the rest of the pipeline run so mid-recording cycling (Step 2)
    /// affects only the current recording, and post-finish settings churn
    /// can't change pass behaviour underneath us.
    private(set) var currentMode: DictationMode = .write

    /// Fired after every successful Assistant Mode turn so the host can show
    /// (or refresh) the result window. `surfaceWindow` is true when the
    /// result wasn't pasted in place — either DRAFT mode or a paste-fallback
    /// to copy — and the user therefore needs the window to actually read
    /// the output. When false, the host should only refresh the window if
    /// it's already visible (e.g. user is following along a REPLACE thread
    /// they've kept open).
    var onAssistantTurnCompleted: ((_ conversation: Conversation, _ surfaceWindow: Bool) -> Void)?

    /// Set by AppState — asks the host whether the result window is currently
    /// on-screen, and what conversation id it's displaying. Pipeline uses
    /// these to decide whether a new assistant invocation is a continuation
    /// of the active conversation. Kept as closures so Pipeline doesn't
    /// import UI types.
    var resultWindowIsVisible: (() -> Bool)?
    var resultWindowConversationID: (() -> UUID?)?

    /// The conversation that will be continued on the next assistant call,
    /// if continuation triggers fire. Set after every successful turn and
    /// cleared by the result window's "New conversation" button.
    private(set) var activeConversation: Conversation?

    /// Whether the *currently in-flight* assistant invocation is a follow-up
    /// to the active conversation. Set when recording starts so the HUD can
    /// show "Following up" instead of "Speak your instruction". Read by the
    /// HUD view during `.recording(isAssistant: true)`.
    private(set) var nextAssistantIsContinuation: Bool = false

    private var settings: DictatorSettings
    private let recorder = AudioRecorder()
    private let whisper = TranscriptionServiceHolder.shared
    private let parakeet = ParakeetServiceHolder.shared
    private let injector = TextInjector()

    /// Resolves the currently-selected engine to the concrete service plus
    /// the model ID it should run with. Both call sites in the pipeline
    /// (dictation and assistant) go through here so a single switch carries
    /// the engine choice everywhere.
    private var activeASR: (engine: any ASREngine, modelID: String) {
        switch settings.transcriptionEngine {
        case .whisper:
            return (whisper, settings.whisperModelID)
        case .parakeet:
            return (parakeet, settings.parakeetModelID)
        }
    }

    /// Compute a per-recording transcribe budget: 60-second floor plus
    /// 3× the audio duration, capped at five minutes. Generous enough
    /// for slow models on long clips, short enough that a real hang
    /// doesn't keep the HUD spinner up all afternoon.
    private static func transcribeBudgetSeconds(audioSamples: Int) -> Double {
        let audioSeconds = Double(audioSamples) / 16_000
        return min(300, max(60, audioSeconds * 3))
    }

    /// Watchdog that flips the pipeline from `.transcribing` to
    /// `.failed` if the engine doesn't return within `budget` seconds.
    /// Cancellation upstream is cooperative — WhisperKit / FluidAudio
    /// may not check it — so we treat the engine call as fire-and-
    /// forget on timeout: cancel the in-flight pipeline task so its
    /// post-transcribe code bails on `Task.isCancelled`, surface a
    /// clear error to the user via the HUD, and let the orphaned
    /// transcribe drain in the background. The guard on `state` is
    /// what stops the watchdog from clobbering a subsequent dictation
    /// — if the user has already moved past the transcribing phase,
    /// the timeout is moot.
    private func startTranscribeWatchdog(budget: Double) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(budget))
            guard let self, !Task.isCancelled else { return }
            guard case .transcribing = self.state else { return }
            self.inFlightTask?.cancel()
            self.inFlightAssistant = nil
            self.nextAssistantIsContinuation = false
            self.fail("Transcription took longer than \(Int(budget))s and was aborted. Try again, and if it keeps happening switch transcription engine or model in Settings.")
        }
    }

    /// Resolves the currently-selected LLM engine. Thin wrapper around
    /// `settings.activeLLMEngine()` — kept private to Pipeline because the
    /// dispatch needs to happen on the *current* settings snapshot, not whatever
    /// AppState happens to hold right now.
    private func currentLLM() -> (any LLMEngine)? {
        settings.activeLLMEngine()
    }

    private var doneFader: Task<Void, Never>?

    /// The post-capture or assistant pipeline currently running. Stored so
    /// `cancelInFlight()` can abort it — LLM generation checks `Task.isCancelled`
    /// inside its didGenerate callback and stops at the next token, then the
    /// awaiting code bails before delivery.
    private var inFlightTask: Task<Void, Never>?

    private var pendingNote: String?

    /// Stages of the current dictation, captured as each pass completes so we can
    /// snapshot the full journey into the history at the end.
    private struct InFlight {
        var raw: String = ""
        var formatted: String?
        var dictionaryCorrected: String?
        var tidied: String?
        var restructured: String?
    }
    private var inFlight = InFlight()

    /// Non-nil while an Assistant Mode dictation is in progress. Used to route the
    /// release-of-hotkey event to the assistant path instead of the dictation path,
    /// and to carry the captured selection from press → release → LLM. `selection`
    /// is nil if the user had nothing selected — a valid case ("put a list here").
    /// `continuesConversation` is decided at press time (so the HUD can show
    /// "Following up") and frozen for the rest of the in-flight turn.
    private struct InFlightAssistant {
        var selection: String?
        var continuesConversation: Bool
    }
    private var inFlightAssistant: InFlightAssistant?

    /// Set by `finishAssistant` when the user releases the hotkey *before*
    /// `startAssistant`'s setup task has finished awaiting the selection
    /// grab. The setup task checks this flag after the slow await and bails
    /// cleanly to `.idle` instead of pushing the pipeline into `.recording`
    /// with no release path queued. Without this, a quick tap of the
    /// assistant hotkey leaves the engine running indefinitely.
    private var assistantReleasePending: Bool = false

    init(settings: DictatorSettings) {
        self.settings = settings
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording(_, let isAssistant) = state {
                state = .recording(level: level, isAssistant: isAssistant)
            }
        }
        recorder.onReady = { [weak self] in
            self?.handleRecorderReady()
        }
        recorder.onStartFailed = { [weak self] error in
            self?.handleRecorderStartFailed(error: error)
        }
        recorder.onUnexpectedStop = { [weak self] message in
            self?.handleUnexpectedStop(note: message)
        }
    }

    /// Recorder finished warming up (engine running, tap installed). Promote
    /// `.warmingUp` to `.recording` so the HUD switches from "Connecting" to
    /// the live waveform. If we're not in `.warmingUp` any more (user
    /// released the hotkey while the mic was negotiating HFP) the recorder
    /// has already been told to stop; nothing to do here.
    private func handleRecorderReady() {
        guard case .warmingUp(let isAssistant) = state else { return }
        state = .recording(level: 0, isAssistant: isAssistant)
        if settings.playSounds { SoundEffects.shared.playStart() }
    }

    private func handleRecorderStartFailed(error: Error) {
        // Only react if we're still expecting this startup. If we've already
        // moved on (cancelled, etc.) the failure is moot.
        guard case .warmingUp = state else { return }
        inFlightAssistant = nil
        fail("Mic error: \(error.localizedDescription)")
    }

    private func handleUnexpectedStop(note: String) {
        guard case .recording = state else { return }
        let samples = recorder.stop()
        guard samples.count > 8_000 else {
            fail(note)
            return
        }
        pendingNote = note
        Task { await runPostCapture(samples: samples) }
    }

    func settingsChanged(_ new: DictatorSettings) {
        settings = new
    }

    /// Rotates `currentMode` to the next entry in `settings.modes.filter(\.includeInCycle)`,
    /// wrapping at the end. No-op outside `.recording` (mid-flight passes
    /// have already snapshotted the mode; cycling after the user releases
    /// the hotkey would have no effect anyway) and when the cycle has ≤1
    /// entry. Plays a subtle click via `playArm()` so the user gets aural
    /// confirmation without staring at the HUD.
    func cycleMode() {
        guard case .recording = state else { return }
        let cycleable = settings.modes.filter { $0.includeInCycle }
        guard cycleable.count > 1 else { return }
        let currentIdx = cycleable.firstIndex(where: { $0.id == currentMode.id }) ?? -1
        let nextIdx = (currentIdx + 1) % cycleable.count
        currentMode = cycleable[nextIdx]
        if settings.playSounds { SoundEffects.shared.playArm() }
    }

    /// Next mode in the cycle order, used by the HUD to render
    /// "Tab → <next>" while recording. Returns nil when ≤1 cycleable mode.
    var nextCycleMode: DictationMode? {
        let cycleable = settings.modes.filter { $0.includeInCycle }
        guard cycleable.count > 1 else { return nil }
        let currentIdx = cycleable.firstIndex(where: { $0.id == currentMode.id }) ?? -1
        let nextIdx = (currentIdx + 1) % cycleable.count
        return cycleable[nextIdx]
    }

    func startRecording() {
        // If we're sitting in a terminal state (.done / .failed) when the hotkey
        // fires again, snap back to .idle right now. Previously we cancelled the
        // doneFader and bailed on the guard — which permanently stranded us in
        // .done because the fader never got to flip state back.
        switch state {
        case .done, .failed:
            doneFader?.cancel()
            doneFader = nil
            state = .idle
        default:
            break
        }
        guard case .idle = state else { return }
        // Snapshot the mode that will drive this dictation. Resolution order:
        // (1) any mode bound to the frontmost app's bundle ID, (2) the user's
        // configured defaultModeID. Frozen here so mid-pipeline settings
        // churn or app-switching can't change pass behaviour underneath us.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        currentMode = settings.activeMode(forFrontmostBundleID: bundleID)
        // Recorder start is non-blocking and asynchronous — the actual
        // engine setup runs off-main so Bluetooth HFP negotiation (2–5 s on
        // AirPods Max) doesn't beach-ball the main thread. Pipeline sits in
        // `.warmingUp` until the recorder's `onReady` fires (handled in
        // init); the HUD shows "Connecting" with the active device name for
        // the duration.
        state = .warmingUp(isAssistant: false)
        if settings.playSounds { SoundEffects.shared.playArm() }
        recorder.start()
    }

    func finishRecording() {
        // If we're recording for Assistant Mode, ignore — the assistant hotkey's
        // release handler owns this recording session.
        guard inFlightAssistant == nil else { return }
        // User released the hotkey before the mic finished warming up. The
        // engine isn't producing buffers yet, so there's nothing to
        // transcribe — abort the startup and return to idle cleanly.
        if case .warmingUp = state {
            recorder.cancelStart()
            state = .idle
            return
        }
        guard case .recording = state else { return }
        let samples = recorder.stop()
        if settings.playSounds { SoundEffects.shared.playStop() }
        guard samples.count > 8_000 else { // <0.5s of audio @ 16kHz
            state = .idle
            return
        }
        inFlightTask = Task { @MainActor [weak self] in
            await self?.runPostCapture(samples: samples)
            self?.inFlightTask = nil
        }
    }

    private func runPostCapture(samples: [Float]) async {
        state = .transcribing
        let raw: String
        do {
            // NOTE: whisperPromptHint is intentionally NOT passed here. Two
            // attempts at biasing Whisper via promptTokens (a wordlist and a
            // natural-sentence form) both pushed the decoder into no-speech
            // rejection on real audio. The TranscriptionService still accepts
            // `prompt:` (preserved on the concrete class only, not the
            // ASREngine protocol) so we can revisit with a different strategy
            // — likely a runtime-detected previous segment, or a much shorter
            // hint — without re-plumbing.
            let asr = activeASR
            let watchdog = startTranscribeWatchdog(
                budget: Self.transcribeBudgetSeconds(audioSamples: samples.count)
            )
            defer { watchdog.cancel() }
            raw = try await asr.engine.transcribe(samples: samples, modelID: asr.modelID)
        } catch {
            if Task.isCancelled { return }
            fail("Transcribe: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight.raw = trimmed
        // Empty transcript = Whisper heard nothing (no-speech segment, mic
        // muted, hotkey tap with no audio, …). Surface it in the HUD so the
        // user can tell "didn't hear me" apart from "something broke".
        guard !trimmed.isEmpty else {
            fail("No speech detected")
            return
        }

        // Deterministic spoken-cue substitution runs BEFORE the LLM so every
        // engine (including None) gets emoji + punctuation handling. Small
        // local models — especially Apple Foundation's ~3 B — are unreliable
        // at the cue rules in the formatter prompt, so we don't depend on
        // them. The formatter prompt keeps the rules as a backstop for
        // anything the curated map misses. Per-mode gates pick which cue
        // families run — a mode can keep punctuation on while disabling
        // emojis, or only run currency substitution, etc.
        let cueOptions = spokenCuesOptions(for: currentMode)
        if cueOptions.anyEnabled {
            trimmed = SpokenCues.apply(to: trimmed, options: cueOptions)
        }

        var formatted: String
        let formatterLLM = currentLLM()
        if formatterLLM == nil || !currentMode.formattingPassEnabled {
            // No LLM engine, OR the active mode opts out of Pass 1 (e.g. Quick).
            // Ship Whisper's raw transcript through the dictionary pass and out.
            // Skips state .formatting so the HUD doesn't flash a "Formatting…"
            // frame that never does anything.
            formatted = trimmed
            inFlight.formatted = nil
        } else if Self.looksLikeQuestion(trimmed) {
            // Question-shaped input is the highest-risk failure mode for Pass 1 — it's
            // where the formatter is tempted to answer the user instead of transcribing
            // them. Modern Whisper already capitalises and punctuates well (including
            // adding "?"), so skipping Pass 1 here costs only minor punctuation polish
            // while sidestepping the whole class of failure. The Grammar and Structure
            // passes still run; their word-sequence validators catch any drift.
            formatted = trimmed
            inFlight.formatted = nil
        } else {
            state = .formatting
            do {
                formatted = try await formatterLLM!.format(
                    text: trimmed,
                    systemPrompt: currentMode.effectiveFormattingPrompt
                )
            } catch {
                // Fallback: ship raw transcript if LLM fails
                await finish(text: trimmed, warning: "LLM failed: \(error.localizedDescription)")
                return
            }
            // Pass 1 produced nothing — fall back to the raw transcript silently. Modern
            // Whisper already produces capitalised, punctuated text, so the user normally
            // can't tell the difference between LLM-formatted and Whisper-raw output.
            if formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                formatted = trimmed
                inFlight.formatted = nil
            } else if !Self.passOnePreservesContent(raw: trimmed, formatted: formatted) {
                // Model drifted into "helpful assistant" mode and answered the user
                // instead of transcribing them. Detected by checking that input
                // anchor words actually survive in the output. Fall back to Whisper's
                // raw transcript — already capitalised and punctuated — and surface
                // a one-line note in the HUD so the user knows what happened.
                formatted = trimmed
                inFlight.formatted = nil
                pendingNote = "Pass 1 (Formatter) answered the question instead of transcribing it. Used the raw Whisper transcript instead."
            } else {
                inFlight.formatted = formatted
            }
        }

        // User dictionary: deterministic case-insensitive whole-word substitutions
        // applied right after the formatter pass. Subsequent passes (grammar,
        // structure) preserve words, so corrections survive intact. The list
        // itself is global; the per-mode toggle decides whether to apply it
        // (a "raw" mode opts out so words pass through untouched).
        let corrected: String
        if currentMode.vocabularyEnabled {
            corrected = Vocabulary.apply(VocabularyStore.shared.entries, to: formatted)
        } else {
            corrected = formatted
        }
        if corrected != formatted { inFlight.dictionaryCorrected = corrected }

        if Task.isCancelled { return }

        // Optional grammar pass: fixes obvious grammar errors. Validated by
        // word-level edit distance; reverted to the previous output if it strays too far.
        let tidied = await maybeFixGrammar(formatted: corrected)
        if Task.isCancelled { return }

        // Optional structural pass: paragraph breaks and bullet lists for long
        // dictations. Validated by strict word-sequence equality (no word changes).
        let final = await maybeRestructure(formatted: tidied)
        if Task.isCancelled { return }

        let warning = pendingNote
        pendingNote = nil
        await finish(text: final, warning: warning)
    }

    private func maybeFixGrammar(formatted: String) async -> String {
        guard currentMode.grammarPassMode != .off else { return formatted }
        guard let llm = currentLLM() else { return formatted }
        state = .fixingGrammar
        do {
            let tidied = try await llm.tidyGrammar(
                text: formatted,
                systemPrompt: currentMode.effectiveGrammarPrompt
            )
            // Empty output usually means the model echoed the wrapping and the
            // post-processor collapsed it to nothing. Treat as failure.
            guard !tidied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return formatted
            }
            // Tidy uses raw word-Levenshtein with the user-tunable ceiling.
            // Tighten is allowed to delete disfluencies, so we strip a known
            // filler set from both sides before measuring — otherwise dropping
            // 4 ums in a 20-word sentence would look like 20% drift and get
            // rejected. The 0.30 ceiling on the stripped comparison still
            // catches actual paraphrase / hallucination.
            let accepted: Bool
            switch currentMode.grammarPassMode {
            case .off:
                accepted = false // unreachable — short-circuit above
            case .tidy:
                let drift = Self.wordEditFraction(from: formatted, to: tidied)
                accepted = drift <= currentMode.grammarPassMaxEditFraction
            case .tighten:
                let drift = Self.wordEditFractionStrippingFillers(from: formatted, to: tidied)
                accepted = drift <= 0.30
            }
            if accepted {
                inFlight.tidied = tidied
                return tidied
            }
            return formatted
        } catch {
            return formatted
        }
    }

    private func maybeRestructure(formatted: String) async -> String {
        guard currentMode.structuralPassEnabled else { return formatted }
        guard let llm = currentLLM() else { return formatted }
        let wordCount = Self.wordSequence(formatted).count
        guard wordCount >= currentMode.structuralPassMinWords else { return formatted }

        state = .restructuring
        do {
            let restructured = try await llm.restructure(
                text: formatted,
                systemPrompt: currentMode.effectiveStructuralPrompt
            )
            guard !restructured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return formatted
            }
            if Self.wordSequence(restructured) == Self.wordSequence(formatted) {
                inFlight.restructured = restructured
                return restructured
            }
            return formatted
        } catch {
            return formatted
        }
    }

    /// Fraction of words that differ between two outputs, used to decide whether the
    /// grammar pass stayed inside its lane. 0 = identical, 1 = totally different.
    private static func wordEditFraction(from a: String, to b: String) -> Double {
        let aw = wordSequence(a)
        let bw = wordSequence(b)
        let n = max(aw.count, bw.count)
        guard n > 0 else { return 0 }
        return Double(wordLevenshtein(aw, bw)) / Double(n)
    }

    /// Drift measure for the `.tighten` mode. We strip known speech fillers
    /// and articles from BOTH sides before computing Levenshtein, so the
    /// validator doesn't punish the model for dropping ums, false starts, or
    /// adding/removing articles — those are the changes we want it to make.
    /// What's still measured: substantive substitutions and additions of
    /// content words, which is where actual hallucination would show up.
    private static func wordEditFractionStrippingFillers(from a: String, to b: String) -> Double {
        let aw = wordSequence(a).filter { !grammarFillerStripSet.contains($0) }
        let bw = wordSequence(b).filter { !grammarFillerStripSet.contains($0) }
        let n = max(aw.count, bw.count)
        guard n > 0 else { return 0 }
        return Double(wordLevenshtein(aw, bw)) / Double(n)
    }

    /// Single-word fillers that the tighten validator ignores on both sides.
    /// Intentionally lenient — the goal is to not REJECT legitimate filler
    /// removal, not to require it. The model isn't told this list; it's just
    /// a safety relaxation. Multi-word fillers ("you know", "I mean") aren't
    /// here because their components are normal words elsewhere — they'll
    /// usually drop out via Levenshtein's deletion cost staying under the
    /// 0.30 ceiling.
    private static let grammarFillerStripSet: Set<String> = [
        "um", "umm", "uh", "uhh", "ah", "ahh", "er", "erm", "ehm",
        "hmm", "mm", "mhm",
        "like", "well", "basically", "literally", "actually",
        "just", "really", "so",
        "a", "an", "the",
    ]

    private static func wordLevenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// Returns the input as a sequence of lowercased alphanumeric "words" — used to
    /// verify the structural pass didn't change any content.
    private static func wordSequence(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Detects the common failure where Pass 1 answers the user's question instead
    /// of transcribing it. Two checks, both must pass:
    ///
    /// 1. **Length**: the formatter never *adds* content words. If the output is
    ///    materially longer than the input (more than +3 words and more than 1.15× the
    ///    input word count), the model elaborated — almost always because it answered
    ///    the question. This catches the failure mode the anchor check is blind to:
    ///    answers that quote the question back ("The formatter returns empty
    ///    because…") still hit all the anchors but expand the output.
    ///
    /// 2. **Anchors**: ≥60% of the input's content words (≥4 chars, not in our spoken-
    ///    punctuation trigger vocabulary) must survive in the output. Short inputs
    ///    (<3 anchors) skip this — too few signals to discriminate cleanly (e.g.
    ///    "fire emoji" → "🔥" has zero anchor survival but is correct).
    static func passOnePreservesContent(raw: String, formatted: String) -> Bool {
        let rawWords = wordSequence(raw)
        let fmtWords = wordSequence(formatted)

        // Length check. Allow small additions (contractions split, etc.) but reject
        // anything that visibly expands — that's the model writing an answer.
        let maxAllowed = max(rawWords.count + 3, Int(ceil(Double(rawWords.count) * 1.15)))
        if fmtWords.count > maxAllowed { return false }

        let anchors = anchorWords(raw)
        guard anchors.count >= 3 else { return true }
        let outputSet = Set(fmtWords)
        let hits = anchors.filter { outputSet.contains($0) }
        return Double(hits.count) / Double(anchors.count) >= 0.6
    }

    private static let passOneTriggerWords: Set<String> = [
        "comma", "period", "stop", "question", "mark", "exclamation", "point",
        "colon", "semicolon", "paren", "parens", "dash", "quote", "quotes",
        "emoji", "line", "newline", "paragraph", "open", "close"
    ]

    private static func anchorWords(_ s: String) -> [String] {
        wordSequence(s).filter { word in
            word.count >= 4 && !passOneTriggerWords.contains(word)
        }
    }

    /// Heuristic for question-shaped input. When true we bypass the formatter pass
    /// to avoid the "model answers instead of transcribes" failure. Triggers on a
    /// trailing "?" (the strongest signal — Whisper already gave us one) or a
    /// classic interrogative first word ("why", "how", "what", ...). False positives
    /// just lose minor punctuation polish; we trust Whisper's already-capitalised,
    /// already-punctuated output.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let firstWord = trimmed.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
            .map(String.init) ?? ""
        return questionStarters.contains(firstWord)
    }

    private static let questionStarters: Set<String> = [
        "why", "how", "what", "who", "when", "where", "which"
    ]

    /// Project the mode's five spoken-cue toggles onto the struct
    /// SpokenCues consumes. Kept here (rather than as a convenience init
    /// on `SpokenCues.Options`) so SpokenCues itself stays unaware of
    /// `DictationMode`.
    private func spokenCuesOptions(for mode: DictationMode) -> SpokenCues.Options {
        SpokenCues.Options(
            punctuation: mode.punctuationCuesEnabled,
            numbers: mode.numberCuesEnabled,
            times: mode.timeCuesEnabled,
            currency: mode.currencyCuesEnabled,
            emojis: mode.emojiCuesEnabled
        )
    }

    /// Ensures the delivered text ends with a single trailing whitespace so that
    /// continuing to type (or starting another dictation right after) doesn't glue
    /// the next character onto the end of this chunk. No-op if the text already
    /// ends in whitespace (e.g. a structural pass that ended with a newline).
    static func withTrailingSpace(_ s: String) -> String {
        guard let last = s.last, !last.isWhitespace else { return s }
        return s + " "
    }

    /// Drop the auto-capitalisation and trailing period when the user has
    /// dictated something short — chat replies, mid-document edits, casual
    /// IDE input, etc. The threshold (≤ 6 words) is calibrated to catch
    /// single-utterance messages without catching anything that reads like
    /// a complete formal sentence. Skipped when the text contains a
    /// strong sentence break ("." mid-text, "?" or "!" anywhere), since
    /// those signal the user is dictating multiple sentences. The first
    /// word is left untouched if it starts with "I" / "I'…" so the
    /// pronoun keeps its proper case.
    static func relaxShortMessage(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard words.count <= 6 else { return text }
        // Internal "." or any "?"/"!" → formal multi-sentence content;
        // leave alone. `dropLast` ignores a single trailing period when
        // checking for an *internal* one.
        let body = trimmed.dropLast()
        if body.contains(".") || trimmed.contains("?") || trimmed.contains("!") {
            return text
        }
        var result = trimmed
        // Strip a single trailing period, but not an ellipsis ("...").
        if result.hasSuffix(".") && !result.hasSuffix("..") {
            result = String(result.dropLast())
        }
        // Lowercase the first letter unless the first word is "I" or a
        // contraction like "I'm", "I'll", "I've", "I'd".
        let firstWord = result
            .split(separator: " ", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let isIWord = firstWord == "I" || firstWord.hasPrefix("I'") || firstWord.hasPrefix("I’")
        if !isIWord, let firstChar = result.first, firstChar.isUppercase {
            result = String(firstChar).lowercased() + result.dropFirst()
        }
        // Restore the original trailing whitespace/newline so the
        // delivery path's `withTrailingSpace` stays a no-op when we
        // already had one (and doesn't need to know we touched anything).
        if let lastChar = text.last, lastChar.isWhitespace, !result.hasSuffix(String(lastChar)) {
            result.append(lastChar)
        }
        return result
    }

    private func finish(text: String, warning: String?) async {
        // Trailing space so the next dictation/keystroke doesn't glue itself to this
        // chunk. Particularly important when piping dictation straight into chat apps
        // (Claude, Slack, …) where back-to-back dictations would otherwise mash.
        var text = text
        let cueOptions = spokenCuesOptions(for: currentMode)
        if cueOptions.anyEnabled {
            // Re-apply SpokenCues after the LLM pass. The formatter
            // prompt forbids it, but small local models still sometimes
            // revert substitutions — most visibly the unary "+44" being
            // rewritten back to "Plus 44". apply() is idempotent, so
            // re-running on text that's already clean is a no-op.
            text = SpokenCues.apply(to: text, options: cueOptions)
        }
        text = Self.relaxShortMessage(text)
        if cueOptions.emojis {
            // Strip LLM-introduced separators between adjacent emojis
            // ("🔥, 🎉" → "🔥 🎉"). Apple Foundation in particular tends to
            // list-format substituted emojis. Gated by the emoji toggle
            // specifically — punctuation/numbers/etc. can be off without
            // skipping this cleanup.
            text = SpokenCues.tidyDelivery(text)
        }
        text = Self.withTrailingSpace(text)
        lastResult = text
        var pasted = false
        var note: String? = warning

        if settings.pasteAutomatically {
            switch injector.deliver(text: text) {
            case .pasted:
                pasted = true
            case .copiedOnly(let reason):
                pasted = false
                note = reason
            }
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        // Snapshot the entire dictation into history before flipping to .done.
        let record = DictationRecord(
            id: UUID(),
            timestamp: Date(),
            raw: inFlight.raw,
            formatted: inFlight.formatted,
            dictionaryCorrected: inFlight.dictionaryCorrected,
            tidied: inFlight.tidied,
            restructured: inFlight.restructured,
            final: text,
            pasted: pasted,
            inputDevice: AudioDeviceManager.shared.activeInputDeviceName(),
            note: note
        )
        DictationHistory.shared.append(record)
        inFlight = InFlight()

        state = .done(text: text, pasted: pasted, note: note)
        if settings.playSounds { SoundEffects.shared.playDone() }
        // Hold the HUD longer when there's something for the user to read.
        let lingerMs = note == nil ? 1400 : 4000
        doneFader = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(lingerMs))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        doneFader = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }

    // MARK: - Assistant Mode

    /// Entry point for the Assistant Mode hotkey press. Grabs the current selection
    /// (synchronously enough that the user holding the hotkey still feels responsive),
    /// then starts the recorder so the user can dictate their instruction.
    func startAssistant() {
        switch state {
        case .done, .failed:
            doneFader?.cancel()
            doneFader = nil
            state = .idle
        default:
            break
        }
        guard case .idle = state else { return }
        guard settings.llmEngine != .none else {
            fail("Assistant Mode needs an LLM. Pick one in Settings → Models.")
            return
        }
        state = .capturingSelection
        // Reset the early-release flag for this attempt — leftover `true`
        // from a prior aborted setup would silently swallow this press.
        assistantReleasePending = false
        Task { [weak self] in
            guard let self else { return }
            do {
                // Selection is optional — Assistant Mode also handles "insert here"
                // style requests where the user has no selection (e.g. "make me a
                // list of ten ideas here please").
                let selection = try await SelectionGrabber.grab()
                // User released before selection-grab finished. Don't start
                // the recorder — just return to idle. Without this the
                // engine starts with no release path queued and the
                // pipeline gets stuck in `.recording` indefinitely.
                if self.assistantReleasePending {
                    self.assistantReleasePending = false
                    self.state = .idle
                    return
                }
                let continues = self.shouldContinueConversation(selection: selection)
                self.nextAssistantIsContinuation = continues
                inFlightAssistant = InFlightAssistant(selection: selection, continuesConversation: continues)
                // Same async-warmup story as `startRecording`: recorder
                // start is non-blocking so BT HFP negotiation doesn't
                // stall the assistant flow. handleRecorderReady promotes
                // `.warmingUp(isAssistant: true)` to `.recording(...)`.
                state = .warmingUp(isAssistant: true)
                if settings.playSounds { SoundEffects.shared.playArm() }
                recorder.start()
            } catch SelectionGrabber.GrabError.noAccessibility {
                // If the user released during the failed grab, drop the
                // error — they've already given up on this press, surfacing
                // a permission alert now would be confusing.
                if self.assistantReleasePending {
                    self.assistantReleasePending = false
                    self.state = .idle
                } else {
                    fail("Accessibility permission required for Assistant Mode.")
                }
            } catch {
                if self.assistantReleasePending {
                    self.assistantReleasePending = false
                    self.state = .idle
                } else {
                    fail("Assistant: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Decides whether the next assistant invocation should be a follow-up
    /// against `activeConversation`. Two paths in:
    ///
    /// 1. The result window is currently visible AND is displaying the active
    ///    conversation. The user is clearly continuing the on-screen thread.
    /// 2. The user has a selection that overlaps the active conversation's
    ///    last reply (i.e. they've kept the previous output selected in their
    ///    editor and triggered Assistant again). Forgiving substring match —
    ///    accommodates light editing on either side.
    ///
    /// Anything else → fresh conversation.
    private func shouldContinueConversation(selection: String?) -> Bool {
        guard let active = activeConversation else { return false }
        if resultWindowIsVisible?() == true, resultWindowConversationID?() == active.id {
            return true
        }
        guard let selection, let lastReply = active.lastReply else { return false }
        return Self.selectionMatchesReply(selection: selection, reply: lastReply)
    }

    /// Forgiving overlap check: trimmed selection contained in the last reply,
    /// or vice versa. The 8-character minimum keeps tiny selections ("yes",
    /// "ok") from accidentally triggering continuation against a long reply
    /// that happens to contain them.
    static func selectionMatchesReply(selection: String, reply: String) -> Bool {
        let trimSel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimRep = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimSel.count >= 8 else { return false }
        return trimRep.contains(trimSel) || trimSel.contains(trimRep)
    }

    /// Called by the result window's "New conversation" button. Clears the
    /// follow-up state so the next assistant call starts fresh.
    func endActiveConversation() {
        activeConversation = nil
        nextAssistantIsContinuation = false
    }

    /// Called when the user reopens a past conversation from the menu bar.
    /// The next assistant call will continue it (subject to the usual
    /// window-visible / selection-match triggers).
    func setActiveConversation(_ conversation: Conversation) {
        activeConversation = conversation
    }

    /// User-initiated abort, triggered from the HUD's hover cancel button.
    /// Handles every non-idle state:
    ///   - recording: stops the recorder and discards the buffer
    ///   - thinking states: cancels the in-flight Task. LLM generation sees
    ///     this via its didGenerate cancellation closure and stops at the
    ///     next token; the awaiting pipeline code checks `Task.isCancelled`
    ///     after each await and bails before delivery.
    func cancelInFlight() {
        if case .recording = state {
            _ = recorder.stop()
            if settings.playSounds { SoundEffects.shared.playStop() }
        } else if case .warmingUp = state {
            recorder.cancelStart()
        }
        inFlightTask?.cancel()
        inFlightTask = nil
        inFlightAssistant = nil
        nextAssistantIsContinuation = false
        pendingNote = nil
        doneFader?.cancel()
        doneFader = nil
        state = .idle
    }

    /// Entry point for the Assistant Mode hotkey release. If the press succeeded in
    /// grabbing a selection and starting the recorder, this runs Whisper on the
    /// dictated instruction and then calls the assistant LLM.
    func finishAssistant() {
        // Release fired while `startAssistant`'s setup task is still
        // awaiting the selection grab. Mark the press for abort — the
        // setup task checks this flag after its await and bails to .idle
        // instead of starting the recorder.
        if case .capturingSelection = state {
            assistantReleasePending = true
            return
        }
        // Release fired while the mic was still warming up (likely
        // Bluetooth). Abort the startup and return to idle without
        // attempting a transcribe — no audio was captured.
        if case .warmingUp = state {
            recorder.cancelStart()
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            state = .idle
            return
        }
        guard let inflight = inFlightAssistant else {
            // Press path failed (no selection, no AX permission, etc.) — release is a no-op.
            return
        }
        guard case .recording = state else { return }
        let samples = recorder.stop()
        if settings.playSounds { SoundEffects.shared.playStop() }
        guard samples.count > 8_000 else {
            inFlightAssistant = nil
            state = .idle
            return
        }
        let capturedSelection = inflight.selection
        inFlightTask = Task { @MainActor [weak self] in
            await self?.runAssistantPipeline(samples: samples, selection: capturedSelection)
            self?.inFlightTask = nil
        }
    }

    private func runAssistantPipeline(samples: [Float], selection: String?) async {
        let inflight = inFlightAssistant
        let continues = inflight?.continuesConversation ?? false

        state = .transcribing
        let instructionRaw: String
        do {
            let asr = activeASR
            let watchdog = startTranscribeWatchdog(
                budget: Self.transcribeBudgetSeconds(audioSamples: samples.count)
            )
            defer { watchdog.cancel() }
            instructionRaw = try await asr.engine.transcribe(samples: samples, modelID: asr.modelID)
        } catch {
            if Task.isCancelled { return }
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("Transcribe: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }
        var instruction = instructionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("No instruction heard")
            return
        }
        // Apply spoken-cue substitution to the instruction only — the
        // selection is the user's pre-existing text from another app and
        // shouldn't be touched. Assistant Mode is a separate flow with no
        // mode binding, so the substitution is always on here — disabling
        // it would silently swallow user-spoken punctuation in their
        // instruction with no surface to expose it.
        instruction = SpokenCues.apply(to: instruction)

        // Resolve prior context for this turn. If continuing, take the verbatim
        // tail (turns after the compaction cutoff) plus the existing summary.
        // Otherwise we send nothing — a fresh conversation.
        var priorTurns: [ConversationTurn] = []
        var summary: String? = nil
        if continues, let active = activeConversation {
            if let comp = active.compaction {
                priorTurns = Array(active.turns.dropFirst(comp.upThroughTurnIndex + 1))
                summary = comp.summary
            } else {
                priorTurns = active.turns
                summary = nil
            }
        }

        // The Assistant Mode entry-point already guarded against .none, so
        // currentLLM() here is non-nil under normal flow. If settings flipped
        // mid-flight (unlikely) we fail cleanly.
        guard let llm = currentLLM() else {
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("LLM is disabled. Pick one in Settings → Models.")
            return
        }

        // Pre-call compaction. Estimate input tokens; if over budget, summarise
        // the oldest turns (always keeping at least the last 2 verbatim). On
        // summariser failure we surface a hard "conversation too long" error
        // rather than silently dropping context — the user said that's the
        // right call.
        var pendingCompactionIndex: Int? = nil
        let estimate = ConversationContextBudget.estimateInputTokens(
            priorTurns: priorTurns, summary: summary,
            selection: selection, instruction: instruction
        )
        if estimate > llm.assistantInputTokenBudget {
            guard priorTurns.count > 2, let active = activeConversation else {
                inFlightAssistant = nil
                nextAssistantIsContinuation = false
                fail("This conversation is too long. Start a new one.")
                return
            }
            let toSummarise = Array(priorTurns.prefix(priorTurns.count - 2))
            let keep = Array(priorTurns.suffix(2))
            state = .compacting
            do {
                let newSummary = try await llm.summariseConversation(
                    turns: toSummarise,
                    priorSummary: summary,
                    cancellation: { Task.isCancelled }
                )
                if Task.isCancelled { return }
                summary = newSummary
                priorTurns = keep
                // Index of the last summarised turn within the *full* turn list.
                // active.turns.count - keep.count - 1 = the last index now compacted.
                pendingCompactionIndex = active.turns.count - keep.count - 1
            } catch {
                if Task.isCancelled { return }
                inFlightAssistant = nil
                nextAssistantIsContinuation = false
                fail("This conversation is too long. Start a new one.")
                return
            }
        }

        state = .assisting
        let result: AssistantResult
        do {
            result = try await llm.assist(
                selection: selection,
                instruction: instruction,
                systemPrompt: settings.effectiveAssistantPrompt,
                priorTurns: priorTurns,
                summary: summary,
                cancellation: { Task.isCancelled }
            )
        } catch {
            if Task.isCancelled { return }
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("Assistant: \(error.localizedDescription)")
            return
        }
        if Task.isCancelled { return }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            inFlightAssistant = nil
            nextAssistantIsContinuation = false
            fail("Assistant returned no output.")
            return
        }

        // Build the new turn and fold it into the conversation. New
        // conversations are appended to history; follow-ups update in place.
        let newTurn = ConversationTurn(
            id: UUID(),
            timestamp: Date(),
            instruction: instruction,
            selection: selection,
            mode: result.mode,
            reply: text
        )
        let updatedConversation: Conversation
        if continues, var active = activeConversation {
            if let idx = pendingCompactionIndex {
                active.compaction = ConversationCompaction(summary: summary ?? "", upThroughTurnIndex: idx)
            }
            active.append(newTurn)
            updatedConversation = active
            ConversationHistory.shared.update(active)
        } else {
            let fresh = Conversation.new(firstTurn: newTurn)
            updatedConversation = fresh
            ConversationHistory.shared.append(fresh)
        }
        activeConversation = updatedConversation

        await deliverAssistant(
            text: text,
            mode: result.mode,
            hadSelection: selection != nil,
            conversation: updatedConversation
        )
        inFlightAssistant = nil
        nextAssistantIsContinuation = false
    }

    private func deliverAssistant(text: String, mode: AssistantMode, hadSelection: Bool, conversation: Conversation) async {
        // Trailing space so the next keystroke doesn't glue itself to this chunk —
        // same reasoning as `finish()`. Assistant Mode is mode-less, so the
        // emoji-tidy pass always runs — matches the always-on substitution on
        // the instruction side.
        var text = text
        text = SpokenCues.tidyDelivery(text)
        text = Self.withTrailingSpace(text)
        lastResult = text
        var pasted = false
        var note: String

        // Conversation mode: the result window is already open, so the user is
        // conversing with the assistant rather than editing in another app.
        // Never paste in this state, regardless of the model's REPLACE/DRAFT
        // classification — the reply just appends to the conversation, which
        // the window picks up automatically via ConversationHistory. Closing
        // the window ends conversation mode (and clears activeConversation).
        let inConversationMode = resultWindowIsVisible?() == true
        if inConversationMode {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pasted = false
            note = "Added to conversation"
        } else {
            switch mode {
            case .replace:
                // Only synthesise ⌘V if the focused element is actually an editable
                // text input. Otherwise the paste would land somewhere unintended —
                // a URL bar, a search box on a web page the user wasn't typing
                // into, or simply nowhere at all. Fall back to DRAFT-style
                // clipboard + window so the user can read and place it themselves.
                if !TextInjector.focusedElementIsEditableText() {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    pasted = false
                    note = "No text input focused — copied to clipboard"
                    break
                }
                // Paste-replace the still-selected text, or insert at the cursor if
                // there was no selection. TextInjector handles both — synthetic ⌘V
                // overwrites a selection if one exists, or just inserts otherwise.
                // selectAfterPaste keeps the just-inserted text selected so the
                // user can immediately reprompt the assistant on it.
                switch injector.deliver(text: text, selectAfterPaste: true) {
                case .pasted:
                    pasted = true
                    note = hadSelection ? "Replaced selection" : "Inserted"
                case .copiedOnly(let reason):
                    pasted = false
                    note = reason
                }
            case .draft:
                // Draft mode: never paste — just leave the result on the clipboard so
                // the user pastes it wherever they actually want it.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                pasted = false
                note = "Copied — ⌘V to paste"
            }
        }

        // Always notify the host that a turn finished. When the result is on
        // the clipboard rather than pasted, the host surfaces the window so
        // the user can read it; otherwise it only refreshes the window if
        // it's already open (e.g. a multi-turn REPLACE thread).
        onAssistantTurnCompleted?(conversation, !pasted)

        state = .done(text: text, pasted: pasted, note: note)
        if settings.playSounds { SoundEffects.shared.playDone() }
        // Assistant outputs are often longer than dictation transcripts — give the
        // user time to actually read what just landed before the HUD fades.
        doneFader = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(3500))
            guard !Task.isCancelled else { return }
            self?.state = .idle
        }
    }
}
