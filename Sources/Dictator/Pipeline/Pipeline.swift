import Foundation
import Observation
import AppKit

enum PipelineState: Equatable {
    case idle
    case recording(level: Float)
    case transcribing
    case formatting
    case fixingGrammar
    case restructuring
    case done(text: String, pasted: Bool, note: String?)
    case failed(String)

    var iconName: String {
        switch self {
        case .idle: "mic"
        case .recording: "waveform"
        case .transcribing: "waveform.badge.magnifyingglass"
        case .formatting: "sparkles"
        case .fixingGrammar: "text.badge.checkmark"
        case .restructuring: "list.bullet.indent"
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

    init(settings: DictatorSettings) {
        self.settings = settings
        recorder.onLevel = { [weak self] level in
            guard let self else { return }
            if case .recording = state {
                state = .recording(level: level)
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
            state = .recording(level: 0)
            if settings.playSounds { SoundEffects.shared.playStart() }
        } catch {
            fail("Mic error: \(error.localizedDescription)")
        }
    }

    func finishRecording() {
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

        state = .formatting
        var formatted: String
        do {
            formatted = try await llm.format(
                text: trimmed,
                modelID: settings.llmModelID,
                systemPrompt: settings.systemPrompt
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
        } else {
            inFlight.formatted = formatted
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
        state = .fixingGrammar
        do {
            let tidied = try await llm.tidyGrammar(
                text: formatted,
                modelID: settings.llmModelID,
                systemPrompt: settings.grammarPrompt
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
        let wordCount = Self.wordSequence(formatted).count
        guard wordCount >= settings.structuralPassMinWords else { return formatted }

        state = .restructuring
        do {
            let restructured = try await llm.restructure(
                text: formatted,
                modelID: settings.llmModelID,
                systemPrompt: settings.structuralPrompt
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

    private func finish(text: String, warning: String?) async {
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
}
