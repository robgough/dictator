import Foundation

/// How the assistant's reply should be delivered. Set by the LLM (REPLACE / DRAFT
/// marker on the first line — see the assistant prompt's few-shot examples) and
/// honoured by Pipeline.deliverAssistant.
enum AssistantMode: String, Sendable, Codable, Hashable {
    case replace
    case draft
}

struct AssistantResult: Sendable {
    let mode: AssistantMode
    let text: String
}

/// Common surface for every LLM backend the pipeline can drive. Two implementations
/// today: `MLXLLMService` (downloads a HuggingFace checkpoint and runs it via MLX-Swift)
/// and `AppleFoundationLLMService` (drives the OS-resident Apple Foundation model
/// from the FoundationModels framework — no download, no in-process weights).
///
/// Mirrors the shape of `ASREngine`: a small protocol both concrete services conform
/// to, Pipeline dispatches via `activeLLM` based on `settings.llmEngine`, and the
/// per-pass validators (anchor check, Levenshtein drift, word-sequence equality) live
/// in Pipeline so they apply uniformly to whichever engine produced the text.
///
/// Engine identity carries model selection — there is no `modelID:` parameter on the
/// per-call API. `MLXLLMService` exposes a `modelID` property the dispatcher sets
/// before each call; `AppleFoundationLLMService` has no equivalent (the OS picks
/// the model).
@MainActor
protocol LLMEngine: AnyObject {
    /// True while a load / first-use warm-up is in flight. Drives Settings "Loading…"
    /// affordances.
    var isLoading: Bool { get }

    /// Bring the engine to a state where the per-pass methods can be called. For MLX
    /// this means downloading-if-needed and loading the model into RAM. For Apple
    /// Foundation this is a cheap availability check that throws
    /// `AppleFoundationLLMService.Unavailable` when the system can't serve a request
    /// (Apple Intelligence off, model still downloading, device ineligible).
    func ensureReady() async throws

    /// Drop any in-process state the engine is holding. MLX drops its container;
    /// Apple Foundation no-ops (model is system-resident).
    func unload()

    func format(text: String, systemPrompt: String) async throws -> String
    func tidyGrammar(text: String, systemPrompt: String) async throws -> String
    func restructure(text: String, systemPrompt: String) async throws -> String

    /// `context` is the document text surrounding the selection/cursor in the
    /// focused app (read via Accessibility at hotkey-press). nil when none was
    /// available — no permission, or the app doesn't expose ranged text. Used
    /// only by the interactive Assistant Mode path; the Meetings callers go
    /// through the contextless convenience overload below.
    func assist(
        selection: String?,
        instruction: String,
        systemPrompt: String,
        priorTurns: [ConversationTurn],
        summary: String?,
        context: InsertionContext?,
        cancellation: @Sendable @escaping () -> Bool
    ) async throws -> AssistantResult

    func summariseConversation(
        turns: [ConversationTurn],
        priorSummary: String?,
        cancellation: @Sendable @escaping () -> Bool
    ) async throws -> String

    /// Conservative token budget for the priorTurns+summary+selection+instruction
    /// payload of an `assist` call. Pipeline compares against this before each
    /// assistant turn and triggers `summariseConversation` when it'd overflow.
    /// For MLX this is derived from the model's native context window minus the
    /// reservation for system prompt + reply (see ConversationContextBudget); for
    /// Apple Foundation we use a fixed conservative figure because the framework
    /// doesn't expose its context limit.
    var assistantInputTokenBudget: Int { get }
}

extension LLMEngine {
    /// Runs one dictation step. A step is just a system prompt plus a token
    /// budget, so this dispatches to the existing pass methods by budget tier:
    /// `.normal` uses the tight formatter cap (1.20× + 8), `.expanded` uses the
    /// generous restructuring cap (1.60× + 32) for steps that legitimately grow
    /// the text with list markers and breaks. The per-step gate in Pipeline does
    /// the validation, uniformly across engines.
    func runStep(text: String, systemPrompt: String, budget: StepBudget) async throws -> String {
        switch budget {
        case .normal:   return try await format(text: text, systemPrompt: systemPrompt)
        case .expanded: return try await restructure(text: text, systemPrompt: systemPrompt)
        }
    }

    /// Convenience overload for callers that have no surrounding-document
    /// context to supply — the Meetings pipeline (speaker naming, notes,
    /// summaries) drives the assistant LLM as a plain text transform. Forwards
    /// with `context: nil` so only the interactive Assistant Mode path has to
    /// know about document context.
    func assist(
        selection: String?,
        instruction: String,
        systemPrompt: String,
        priorTurns: [ConversationTurn],
        summary: String?,
        cancellation: @Sendable @escaping () -> Bool
    ) async throws -> AssistantResult {
        try await assist(
            selection: selection,
            instruction: instruction,
            systemPrompt: systemPrompt,
            priorTurns: priorTurns,
            summary: summary,
            context: nil,
            cancellation: cancellation
        )
    }
}
