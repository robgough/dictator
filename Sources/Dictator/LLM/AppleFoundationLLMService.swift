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

    func tidyGrammar(text: String, systemPrompt: String) async throws -> String {
        try await runDeterministicPass(text: text, systemPrompt: systemPrompt,
                                       maxTokenMultiplier: 1.20, maxTokenConstant: 8)
    }

    func restructure(text: String, systemPrompt: String) async throws -> String {
        // Structure pass adds tokens (bullet markers, blank lines) even though no
        // words change — the same 1.60× + 32 cap shape MLX uses.
        try await runDeterministicPass(text: text, systemPrompt: systemPrompt,
                                       maxTokenMultiplier: 1.60, maxTokenConstant: 32)
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
        let maxTokens = min(2048,
                            max(24,
                                Int(Double(approxInputTokens) * maxTokenMultiplier) + maxTokenConstant))
        let options = GenerationOptions(
            sampling: .greedy,
            temperature: 0.0,
            maximumResponseTokens: maxTokens
        )
        let response = try await session.respond(
            to: LLMTextUtilities.wrapAsData(text),
            options: options
        )
        return LLMTextUtilities.clean(response.content)
    }

    func assist(
        selection: String?,
        instruction: String,
        systemPrompt: String,
        priorTurns: [ConversationTurn],
        summary: String?,
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
            summary: summary
        )
        let options = GenerationOptions(
            temperature: 0.2,
            maximumResponseTokens: 4096
        )
        let response = try await session.respond(to: prompt, options: options)
        if cancellation() {
            throw CancellationError()
        }
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
        let cleaned = LLMTextUtilities.clean(response.content)
        guard !cleaned.isEmpty else {
            throw NSError(domain: "Dictator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Summariser returned no text"])
        }
        return cleaned
    }

    // MARK: - Helpers

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
        summary: String?
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
        pieces.append("""
        Current user turn:
        \(LLMTextUtilities.renderAssistantUserMessage(selection: selection, instruction: instruction))
        """)
        return pieces.joined(separator: "\n\n---\n\n")
    }
}
