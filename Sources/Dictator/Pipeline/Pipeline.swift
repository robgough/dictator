import Foundation
import Observation
import AppKit

enum PipelineState: Equatable {
    case idle
    case capturingSelection
    case recording(level: Float, isAssistant: Bool)
    case transcribing
    case formatting
    case fixingGrammar
    case restructuring
    case assisting
    case done(text: String, pasted: Bool, note: String?)
    case failed(String)

    var iconName: String {
        switch self {
        case .idle: "mic"
        case .capturingSelection: "selection.pin.in.out"
        case .recording: "waveform"
        case .transcribing: "waveform.badge.magnifyingglass"
        case .formatting: "sparkles"
        case .fixingGrammar: "text.badge.checkmark"
        case .restructuring: "list.bullet.indent"
        case .assisting: "wand.and.stars"
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
}

@MainActor
@Observable
final class Pipeline {
    private(set) var state: PipelineState = .idle
    private(set) var lastResult: String = ""

    private var settings: DictatorSettings
    private let recorder = AudioRecorder()
    private let transcription = TranscriptionServiceHolder.shared
    private let llm = LLMServiceHolder.shared
    private let injector = TextInjector()

    private var doneFader: Task<Void, Never>?

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
    private struct InFlightAssistant {
        var selection: String?
    }
    private var inFlightAssistant: InFlightAssistant?

    init(settings: DictatorSettings) {
        self.settings = settings
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording(_, let isAssistant) = state {
                state = .recording(level: level, isAssistant: isAssistant)
            }
        }
        recorder.onUnexpectedStop = { [weak self] message in
            self?.handleUnexpectedStop(note: message)
        }
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
        do {
            try recorder.start()
            state = .recording(level: 0, isAssistant: false)
            if settings.playSounds { SoundEffects.shared.playStart() }
        } catch {
            fail("Mic error: \(error.localizedDescription)")
        }
    }

    func finishRecording() {
        // If we're recording for Assistant Mode, ignore — the assistant hotkey's
        // release handler owns this recording session.
        guard inFlightAssistant == nil else { return }
        guard case .recording = state else { return }
        let samples = recorder.stop()
        if settings.playSounds { SoundEffects.shared.playStop() }
        guard samples.count > 8_000 else { // <0.5s of audio @ 16kHz
            state = .idle
            return
        }
        Task { await runPostCapture(samples: samples) }
    }

    private func runPostCapture(samples: [Float]) async {
        state = .transcribing
        let raw: String
        do {
            raw = try await transcription.transcribe(samples: samples, modelID: settings.whisperModelID)
        } catch {
            fail("Transcribe: \(error.localizedDescription)")
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        inFlight.raw = trimmed
        guard !trimmed.isEmpty else { state = .idle; return }

        var formatted: String
        if settings.llmModelID == ModelCatalog.noneLLMID {
            // User opted out of LLM formatting — ship Whisper's raw transcript through
            // the dictionary pass and out. Skips state .formatting so the HUD doesn't
            // flash a "Formatting…" frame that never does anything.
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
                formatted = try await llm.format(
                    text: trimmed,
                    modelID: settings.llmModelID,
                    systemPrompt: settings.effectiveFormattingPrompt
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
        // structure) preserve words, so corrections survive intact.
        let corrected = Vocabulary.apply(settings.vocabulary, to: formatted)
        if corrected != formatted { inFlight.dictionaryCorrected = corrected }

        // Optional grammar pass: fixes obvious grammar errors. Validated by
        // word-level edit distance; reverted to the previous output if it strays too far.
        let tidied = await maybeFixGrammar(formatted: corrected)

        // Optional structural pass: paragraph breaks and bullet lists for long
        // dictations. Validated by strict word-sequence equality (no word changes).
        let final = await maybeRestructure(formatted: tidied)

        let warning = pendingNote
        pendingNote = nil
        await finish(text: final, warning: warning)
    }

    private func maybeFixGrammar(formatted: String) async -> String {
        guard settings.grammarPassEnabled else { return formatted }
        guard settings.llmModelID != ModelCatalog.noneLLMID else { return formatted }
        state = .fixingGrammar
        do {
            let tidied = try await llm.tidyGrammar(
                text: formatted,
                modelID: settings.llmModelID,
                systemPrompt: settings.effectiveGrammarPrompt
            )
            // Empty output usually means the model echoed the wrapping and the
            // post-processor collapsed it to nothing. Treat as failure.
            guard !tidied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return formatted
            }
            let drift = Self.wordEditFraction(from: formatted, to: tidied)
            if drift <= settings.grammarPassMaxEditFraction {
                inFlight.tidied = tidied
                return tidied
            }
            return formatted
        } catch {
            return formatted
        }
    }

    private func maybeRestructure(formatted: String) async -> String {
        guard settings.structuralPassEnabled else { return formatted }
        guard settings.llmModelID != ModelCatalog.noneLLMID else { return formatted }
        let wordCount = Self.wordSequence(formatted).count
        guard wordCount >= settings.structuralPassMinWords else { return formatted }

        state = .restructuring
        do {
            let restructured = try await llm.restructure(
                text: formatted,
                modelID: settings.llmModelID,
                systemPrompt: settings.effectiveStructuralPrompt
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

    /// Ensures the delivered text ends with a single trailing whitespace so that
    /// continuing to type (or starting another dictation right after) doesn't glue
    /// the next character onto the end of this chunk. No-op if the text already
    /// ends in whitespace (e.g. a structural pass that ended with a newline).
    static func withTrailingSpace(_ s: String) -> String {
        guard let last = s.last, !last.isWhitespace else { return s }
        return s + " "
    }

    private func finish(text: String, warning: String?) async {
        // Trailing space so the next dictation/keystroke doesn't glue itself to this
        // chunk. Particularly important when piping dictation straight into chat apps
        // (Claude, Slack, …) where back-to-back dictations would otherwise mash.
        let text = Self.withTrailingSpace(text)
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
        guard settings.llmModelID != ModelCatalog.noneLLMID else {
            fail("Assistant Mode needs an LLM. Pick one in Settings → Models.")
            return
        }
        state = .capturingSelection
        Task { [weak self] in
            guard let self else { return }
            do {
                // Selection is optional — Assistant Mode also handles "insert here"
                // style requests where the user has no selection (e.g. "make me a
                // list of ten ideas here please").
                let selection = try await SelectionGrabber.grab()
                try recorder.start()
                inFlightAssistant = InFlightAssistant(selection: selection)
                state = .recording(level: 0, isAssistant: true)
                if settings.playSounds { SoundEffects.shared.playStart() }
            } catch SelectionGrabber.GrabError.noAccessibility {
                fail("Accessibility permission required for Assistant Mode.")
            } catch {
                fail("Assistant: \(error.localizedDescription)")
            }
        }
    }

    /// Entry point for the Assistant Mode hotkey release. If the press succeeded in
    /// grabbing a selection and starting the recorder, this runs Whisper on the
    /// dictated instruction and then calls the assistant LLM.
    func finishAssistant() {
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
        Task { await runAssistantPipeline(samples: samples, selection: inflight.selection) }
    }

    private func runAssistantPipeline(samples: [Float], selection: String?) async {
        state = .transcribing
        let instructionRaw: String
        do {
            instructionRaw = try await transcription.transcribe(samples: samples, modelID: settings.whisperModelID)
        } catch {
            inFlightAssistant = nil
            fail("Transcribe: \(error.localizedDescription)")
            return
        }
        let instruction = instructionRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            inFlightAssistant = nil
            state = .idle
            return
        }

        state = .assisting
        let result: AssistantResult
        do {
            result = try await llm.assist(
                selection: selection,
                instruction: instruction,
                modelID: settings.llmModelID,
                systemPrompt: settings.effectiveAssistantPrompt
            )
        } catch {
            inFlightAssistant = nil
            fail("Assistant: \(error.localizedDescription)")
            return
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            inFlightAssistant = nil
            fail("Assistant returned no output.")
            return
        }

        await deliverAssistant(text: text, mode: result.mode, hadSelection: selection != nil)
        inFlightAssistant = nil
    }

    private func deliverAssistant(text: String, mode: AssistantMode, hadSelection: Bool) async {
        // Trailing space so the next keystroke doesn't glue itself to this chunk —
        // same reasoning as `finish()`.
        let text = Self.withTrailingSpace(text)
        lastResult = text
        var pasted = false
        var note: String

        switch mode {
        case .replace:
            // Paste-replace the still-selected text, or insert at the cursor if
            // there was no selection. TextInjector handles both — synthetic ⌘V
            // overwrites a selection if one exists, or just inserts otherwise.
            switch injector.deliver(text: text) {
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
