import Foundation
import FoundationModels

/// Apple Foundation Models backed LLM engine. Drives the ~3B on-device LLM that
/// ships with Apple Intelligence (macOS 26+). Zero in-process weight cost — the
/// model is system-resident and shared across every app that uses the framework
/// — so there's no `download`, no `ensureLoaded`, and no `ModelStorage` involvement.
///
/// Availability is gated at runtime by macOS: the user must have an
/// Apple-Intelligence-capable Mac AND have toggled Apple Intelligence on AND
/// have the underlying model fully downloaded. `ensureReady()` translates the
/// framework's availability cases into `Unavailable` errors so Pipeline can
/// surface a useful message in the HUD ("Apple Intelligence is off — enable
/// it in System Settings…") instead of a generic failure.
@MainActor
@Observable
final class AppleFoundationLLMService: LLMEngine {
    /// Apple's framework is system-resident and doesn't have an in-process "loading"
    /// state we can observe — there's nothing to load. Kept as a stored property so
    /// the protocol conformance is satisfied and the Settings UI doesn't have to
    /// special-case this engine for the "Loading…" badge.
    private(set) var isLoading: Bool = false

    /// Conservative fixed budget for the assistant call's input payload. The
    /// FoundationModels framework doesn't expose its context window publicly,
    /// and Apple positions the on-device model as ~4K-context-class. We hold
    /// back ~1K for the system prompt + reply headroom and use the remainder
    /// for prior turns + selection + instruction.
    let assistantInputTokenBudget: Int = 3_000

    enum Unavailable: LocalizedError {
        case appleIntelligenceOff
        case deviceIneligible
        case modelNotReady
        case other(String)

        var errorDescription: String? {
            switch self {
            case .appleIntelligenceOff:
                return "Apple Intelligence is off. Enable it in System Settings → Apple Intelligence & Siri."
            case .deviceIneligible:
                return "This Mac doesn't support Apple Intelligence. Pick a different LLM in Settings → Models."
            case .modelNotReady:
                return "Apple's foundation model is still downloading. Wait a few minutes, then try again."
            case .other(let reason):
                return "Apple Foundation model unavailable: \(reason)."
            }
        }
    }

    func ensureReady() async throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw Self.map(reason)
        }
    }

    /// Engine is system-resident; nothing to release. Implemented so the protocol
    /// conformance is satisfied and Pipeline can call `unload()` symmetrically
    /// across engines after a settings change.
    func unload() {}

    func format(text: String, systemPrompt: String) async throws -> String {
        // Tight reply budget for the formatter — the same 1.20× + 8 cap shape MLX uses.
        try await runDeterministicPass(text: text, systemPrompt: systemPrompt,
                                       maxTokenMultiplier: 1.20, maxTokenConstant: 8)
    }

    /// Plain system+user completion. No `<<< >>>` wrapping and no length
    /// heuristics — the caller states the reply budget, because a structured
    /// reply's size (the paragraph pass returns a few sentence numbers) has
    /// nothing to do with how much text it describes. The refusal / over-length
    /// guards in `runDeterministicPass` are deliberately absent: they measure
    /// the reply against the input, which is meaningless here. A refusal comes
    /// back as text the caller's own parser rejects.
    func complete(system: String, user: String, maxTokens: Int, temperature: Double = 0) async throws -> String {
        try await ensureReady()
        let session = LanguageModelSession(instructions: Instructions(system))
        // Greedy decoding is only correct at temperature 0; a warm request has
        // to switch to random sampling or the temperature is silently ignored.
        let options = GenerationOptions(
            sampling: temperature > 0 ? .random(probabilityThreshold: 0.95) : .greedy,
            temperature: max(0, temperature),
            maximumResponseTokens: max(1, maxTokens)
        )
        let response = try await session.respond(to: user, options: options)
        Self.recordTokenUsage(
            promptCharCount: system.count + user.count,
            responseCharCount: response.content.count
        )
        return LLMTextUtilities.clean(response.content)
    }

    private func runDeterministicPass(
        text: String,
        systemPrompt: String,
        maxTokenMultiplier: Double,
        maxTokenConstant: Int
    ) async throws -> String {
        try await ensureReady()
        let session = LanguageModelSession(instructions: Instructions(systemPrompt))
        let approxInputTokens = max(8, text.count / 4)
        // Floor at 256 so a model that goes off-script (writes a joke
        // instead of formatting the request to write one) produces a
        // complete-looking response we can definitively reject via the
        // length check below. Capping tight just yielded truncated
        // jokes in the HUD.
        let maxTokens = min(2048,
                            max(256,
                                Int(Double(approxInputTokens) * maxTokenMultiplier) + maxTokenConstant))
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: maxTokens
        )
        let promptText = LLMTextUtilities.wrapAsData(text)
        let response = try await session.respond(
            to: promptText,
            options: options
        )
        Self.recordTokenUsage(
            promptCharCount: systemPrompt.count + promptText.count,
            responseCharCount: response.content.count
        )
        let cleaned = LLMTextUtilities.clean(response.content)

        // Length sanity check. A dictation pass should produce output
        // the same order of magnitude as its input — every style's
        // passes are content-preserving rewrites, so they shrink or
        // stay roughly equal. Anything beyond 2× + 50c is the model
        // having written new prose. Throwing here lets the pipeline
        // revert to the previous stage's text.
        let allowedMaxChars = text.count * 2 + 50
        if cleaned.count > allowedMaxChars {
            throw NSError(
                domain: "Dictator",
                code: 43,
                userInfo: [NSLocalizedDescriptionKey: "Apple foundation model output was too long for cleanup (\(cleaned.count) chars vs \(text.count) in) — reverted to previous stage."]
            )
        }
        // Refusal guard. Apple's foundation model occasionally declines
        // the prompt and returns "I'm sorry, I cannot…" even when the
        // input is benign — guardrails firing on words in the dictation
        // it's been asked to format. Input-aware: we only flag when the
        // raw transcript didn't ALSO start with the same shape, so a
        // legitimate dictation like "I'm sorry I can't make it" doesn't
        // false-positive.
        if Self.looksLikeRefusal(input: text, output: cleaned) {
            throw NSError(
                domain: "Dictator",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Apple foundation model refused to process the input — reverted to previous stage."]
            )
        }
        return cleaned
    }

    /// Standard refusal openings used by Apple's (and most other)
    /// foundation models when declining a prompt.
    private static let refusalPrefixes: [String] = [
        "i cannot",
        "i can't",
        "i'm sorry",
        "i am sorry",
        "sorry, i",
        "sorry. i",
        "as an ai",
        "as a language model",
        "i won't",
        "i will not",
        "i'm unable",
        "i am unable",
        "i'm not able",
        "unfortunately, i",
    ]

    /// Input-aware refusal detector: only flags when the output starts
    /// with a refusal-shape AND the input didn't. Keeps legitimate
    /// dictation that happens to open with "I'm sorry" / "I cannot"
    /// from being mistakenly reverted.
    private static func looksLikeRefusal(input: String, output: String) -> Bool {
        let outputHead = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .prefix(48)
        let inputHead = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .prefix(48)
        for prefix in refusalPrefixes {
            if outputHead.hasPrefix(prefix) && !inputHead.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    func assist(
        selection: String?,
        instruction: String,
        systemPrompt: String,
        priorTurns: [ConversationTurn],
        summary: String?,
        context: InsertionContext?,
        cancellation: @Sendable @escaping () -> Bool
    ) async throws -> AssistantResult {
        try await ensureReady()

        // Render any prior history inline into the prompt. Matching the MLX path's
        // turn-by-turn `MODE:`-prefixed assistant messages keeps the model
        // emitting MODE markers on follow-ups — the parser falls back to .draft
        // when the marker is missing, which would silently lose REPLACE intent.
        let session = LanguageModelSession(instructions: Instructions(systemPrompt))
        let prompt = Self.composeAssistantPrompt(
            selection: selection,
            instruction: instruction,
            priorTurns: priorTurns,
            summary: summary,
            context: context
        )
        let options = GenerationOptions(
            temperature: 0.2,
            maximumResponseTokens: 4096
        )
        let response = try await session.respond(to: prompt, options: options)
        if cancellation() {
            throw CancellationError()
        }
        Self.recordTokenUsage(
            promptCharCount: systemPrompt.count + prompt.count,
            responseCharCount: response.content.count
        )
        return LLMTextUtilities.parseAssistant(response.content)
    }

    func summariseConversation(
        turns: [ConversationTurn],
        priorSummary: String?,
        cancellation: @Sendable @escaping () -> Bool
    ) async throws -> String {
        try await ensureReady()

        let rendered = turns.map { turn -> String in
            let sel = turn.selection.flatMap { $0.isEmpty ? nil : $0 }
            let selLine = sel.map { "Selection: \($0)" } ?? "Selection: (none)"
            return """
            ---
            User: \(turn.instruction)
            \(selLine)
            Assistant (MODE: \(turn.mode.rawValue.uppercased())):
            \(turn.reply)
            """
        }.joined(separator: "\n")

        let priorBlock: String
        if let priorSummary, !priorSummary.isEmpty {
            priorBlock = """
            Previous summary so far:
            <<<
            \(priorSummary)
            >>>

            """
        } else {
            priorBlock = ""
        }

        let userText = """
        \(priorBlock)Conversation turns to compact:
        <<<
        \(rendered)
        >>>
        """

        let session = LanguageModelSession(instructions: Instructions(LLMTextUtilities.summariserSystemPrompt))
        let options = GenerationOptions(
            temperature: 0.2,
            maximumResponseTokens: 512
        )
        let response = try await session.respond(to: userText, options: options)
        if cancellation() {
            throw CancellationError()
        }
        Self.recordTokenUsage(
            promptCharCount: LLMTextUtilities.summariserSystemPrompt.count + userText.count,
            responseCharCount: response.content.count
        )
        let cleaned = LLMTextUtilities.clean(response.content)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "Dictator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Summariser returned no text"])
        }
        return cleaned
    }

    // MARK: - Helpers

    /// Approximate LLM token accounting for the just-completed
    /// respond call. The Apple Foundation Models exact tokeniser
    /// (`SystemLanguageModel.tokenCount(for:)`) is only available on
    /// macOS / iOS 26.4+, and the app's deployment target is 26.0,
    /// so we fall back to the industry-standard 4-chars-per-token
    /// approximation for English BPE — accurate to within ~10–15%
    /// for typical dictation and assistant text. Good enough for a
    /// stats line on the About surface. Swap for the exact call
    /// when the deployment target moves to 26.4.
    private static func recordTokenUsage(promptCharCount: Int, responseCharCount: Int) {
        let approxIn = max(0, promptCharCount) / 4
        let approxOut = max(0, responseCharCount) / 4
        UsageStatsStore.shared.recordLLMTokens(in: approxIn, out: approxOut)
    }

    private static func map(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> Unavailable {
        switch reason {
        case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
        case .deviceNotEligible:           return .deviceIneligible
        case .modelNotReady:               return .modelNotReady
        @unknown default:                  return .other(String(describing: reason))
        }
    }

    /// Stitches the system-prompt-free body of an assist call into a single user
    /// prompt that contains any summary, the prior alternating user/assistant
    /// turns, and the current user turn. The FoundationModels framework does
    /// support multi-turn via repeated `respond(to:)` on a single session, but
    /// we drive each turn through a fresh session for parity with the MLX path
    /// — Pipeline owns the conversation history, not the engine.
    private static func composeAssistantPrompt(
        selection: String?,
        instruction: String,
        priorTurns: [ConversationTurn],
        summary: String?,
        context: InsertionContext?
    ) -> String {
        var pieces: [String] = []
        if let summary, !summary.isEmpty {
            pieces.append("""
            [Earlier conversation summary — older turns have been compacted to fit context]
            <<<
            \(summary)
            >>>
            """)
        }
        for turn in priorTurns {
            pieces.append("""
            Previous user turn:
            \(LLMTextUtilities.renderAssistantUserMessage(selection: turn.selection, instruction: turn.instruction))

            Previous assistant reply:
            MODE: \(turn.mode.rawValue.uppercased())
            \(turn.reply)
            """)
        }
        // Document context for the current turn (the surrounding text only
        // describes where the user is now, so it isn't attached to prior turns).
        if let context, context.hasPromptMaterial {
            pieces.append(context.assistantPromptBlock)
        }
        pieces.append("""
        Current user turn:
        \(LLMTextUtilities.renderAssistantUserMessage(selection: selection, instruction: instruction))
        """)
        return pieces.joined(separator: "\n\n---\n\n")
    }
}
