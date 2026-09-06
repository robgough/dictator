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

    /// One content-preserving dictation transform: system prompt + the
    /// transcript as a `<<< >>>`-wrapped data block, capped tightly because a
    /// correctly formatted version is always about as long as its input. The
    /// per-pass gate in Pipeline validates the result.
    func format(text: String, systemPrompt: String) async throws -> String

    /// A plain system+user completion with no data wrapping and no length
    /// assumptions, for the pipeline's structured side-calls — the
    /// auto-paragraph pass, whose reply is a handful of sentence numbers, and
    /// (in Dictator Meetings) every note-writing pass that goes through a
    /// local provider. The output is `LLMTextUtilities.clean`ed like every
    /// other pass, and token usage is recorded.
    ///
    /// `temperature` defaults to 0 — the deterministic setting every in-app
    /// caller wants — and is a parameter only because the meetings assistant
    /// reproduces `assist`'s 0.2 through this entry point, and the socket
    /// server forwards whatever the wire asked for.
    func complete(system: String, user: String, maxTokens: Int, temperature: Double) async throws -> String

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
    /// Temperature-0 shorthand, which is what every dictation call site wants.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, temperature: 0)
    }

    /// Runs one dictation pass. Every style's passes are content-preserving
    /// rewrites — format, polish, messages, a user's own prompt — so they all
    /// share the tight formatter cap (1.20× + 8, floor 24, ceiling 2048). The
    /// generous "expanded" budget the old structural step used is gone: nothing
    /// in the pipeline grows the text any more, and paragraph breaks are applied
    /// deterministically by `DictationText`, never generated.
    func runPass(text: String, systemPrompt: String) async throws -> String {
        try await format(text: text, systemPrompt: systemPrompt)
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

/// A completion plus whatever usage the engine chose to report.
///
/// `LLMEngine.complete` returns bare text because that's all any in-process
/// caller wants — usage is already recorded into `UsageStatsStore` inside the
/// engine. The LLM socket server is the exception: it answers a *different*
/// process, which has no way to see that store, so it needs the counts on the
/// wire. Rather than widen `complete`'s return type across every call site,
/// engines that can report usage cheaply opt in via `LLMUsageReporting`.
struct LLMCompletionResult: Sendable {
    let text: String
    /// nil when the engine doesn't expose the figure (Apple Foundation).
    let promptTokens: Int?
    let completionTokens: Int?
}

/// Opt-in refinement of `complete` for engines that can hand back token counts.
/// `MLXLLMService` conforms (MLX returns both counts from `generate`);
/// `AppleFoundationLLMService` does not, and callers fall back to plain
/// `complete` and send nils.
@MainActor
protocol LLMUsageReporting: AnyObject {
    func completeReportingUsage(system: String, user: String, maxTokens: Int,
                                temperature: Double) async throws -> LLMCompletionResult
}

extension LLMUsageReporting {
    func completeReportingUsage(system: String, user: String, maxTokens: Int) async throws -> LLMCompletionResult {
        try await completeReportingUsage(system: system, user: user, maxTokens: maxTokens, temperature: 0)
    }
}
