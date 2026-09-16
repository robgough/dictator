import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
// For `ToolSpec`, which `LLMChatStreaming.streamChatRound` takes. This engine
// ignores tools, but the protocol it conforms to is shared with the MLX one
// and names MLX's type.
import MLXLMCommon

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
        // Wired up as of macOS 27 GA. This sat unused because the shipping OS
        // was believed to have no image-attachment initializer — it does, and
        // the gate that said otherwise was probing a mistyped symbol. When the
        // caller decides Apple will answer *and* can see, the screenshot comes
        // here and the separate describe-the-screen pass is skipped entirely.
        screenImage: CGImage?,
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
        let response: LanguageModelSession.Response<String>
        if let screenImage, Self.canAttachImages {
            response = try await Self.respondWithImage(
                session: session, prompt: prompt, image: screenImage, options: options)
        } else {
            response = try await session.respond(to: prompt, options: options)
        }
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
    /// Whether this build and this OS can hand the model an image.
    ///
    /// Deliberately not a re-implementation of `WindowVisionContext`'s gate —
    /// that one owns the dlsym probe and the reasoning behind it. This is the
    /// `DictatorMac`-side compile/OS check; the caller has already decided
    /// whether vision is on at all.
    static var canAttachImages: Bool {
        #if FOUNDATION_MODELS_VISION
        if #available(macOS 27.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    private static func respondWithImage(
        session: LanguageModelSession,
        prompt: String,
        image: CGImage,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<String> {
        #if FOUNDATION_MODELS_VISION
        guard #available(macOS 27.0, *) else {
            return try await session.respond(to: prompt, options: options)
        }
        return try await session.respond(options: options) {
            prompt
            Attachment(image)
        }
        #else
        return try await session.respond(to: prompt, options: options)
        #endif
    }

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

// MARK: - Chat

/// A plain, tool-free chat round on Apple's on-device model.
///
/// `LLMChatStreaming`'s own documentation used to say this engine couldn't do
/// this. That was half right, and the half that was wrong cost real
/// functionality: the assistant conversation people had *before* the chat
/// window existed was reachable from the menu bar, and when it moved into the
/// window it went behind an MLX-only gate — so an Apple user could no longer
/// reopen their own threads, let alone add to one.
///
/// What Apple genuinely can't do here is the *agent* half:
///
/// - **Tools.** Not because the capability is missing — the shipping macOS 27
///   model advertises `.toolCalling` — but because Apple's `Tool` protocol
///   wants `@Generable` argument types known at compile time, while every MCP
///   tool arrives with a runtime JSON schema. Bridging that means building a
///   `DynamicGenerationSchema` per tool, which is a project, not a flag.
/// - **A big thread.** 8192 tokens of context (probed on macOS 27.0 GA), and a
///   round re-renders the whole conversation. `ChatEngine` gives this engine a
///   correspondingly small input budget and compacts sooner.
///
/// So this conforms and simply never emits a tool call. `ChatEngine`'s loop
/// then runs exactly one round per turn, which is what a tool-free chat is.
extension AppleFoundationLLMService: LLMChatStreaming {
    /// Probed on macOS 27.0 GA. Not exposed by the framework as a constant, so
    /// it is written down here next to the thing that depends on it.
    static let contextWindowTokens = 8_192

    /// Characters in the text of a rendered thread, for the reply-size bound.
    static func promptCharacters(of messages: [ChatWireMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }

    /// Input budget for a chat turn, well under the probed 8192-token window.
    ///
    /// Deliberately its own number rather than a reuse of
    /// `assistantInputTokenBudget`: that one is sized for a single assist call
    /// with a selection, and changing it would change dictation behaviour that
    /// nobody asked about here. The headroom below the window covers the system
    /// prompt, the reply, and the fact that a character-count estimate of
    /// tokens is only ever approximate — and an Apple overflow is a thrown
    /// error mid-answer, not a graceful truncation, so it's worth being timid.
    static let chatInputTokenBudget = 4_500

    func streamChatRound(
        messages: [ChatWireMessage],
        tools: [ToolSpec],
        maxTokens: Int,
        cacheOwner: String,
        onDelta: @MainActor @escaping (ChatStreamDelta) -> Void
    ) async throws -> ChatRoundResult {
        try await ensureReady()

        // `tools` is accepted and ignored — see the note above. ChatEngine
        // hands this engine an empty toolset, so a non-empty list here means
        // the two have drifted apart; say so in the log rather than silently
        // advertising tools the model will then hallucinate calls to.
        if !tools.isEmpty {
            NSLog("[Dictator] Apple chat round was handed %d tool(s) it can't run — ignoring them.",
                  tools.count)
        }

        let instructions = messages.first { $0.role == .system }?.content ?? ""
        let session = LanguageModelSession(instructions: Instructions(instructions))
        // Bounded against the window, not just taken as given. The caller's cap
        // is 4,096 and the input budget 4,500, which together overshoot the
        // 8,192 Apple actually has — and because the input estimate is
        // characters over four, it undercounts code badly. Overshooting throws
        // `exceededContextWindowSize` *mid-answer*, which is much worse than a
        // slightly shorter reply.
        let promptEstimate = (instructions.count + Self.promptCharacters(of: messages)) / 4
        let room = max(256, Self.contextWindowTokens - promptEstimate - 256)
        let options = GenerationOptions(
            temperature: 0.7,
            maximumResponseTokens: min(maxTokens, room)
        )
        // Rendered as an ordered run of text and images rather than one string, so
        // an image sits where its own message sits. Measured on macOS 27.0 GA: the
        // model keeps two images apart and in order, and answers from an image with
        // text on both sides of it — so the thread can be rendered faithfully
        // rather than by appending every picture at the end and hoping.
        let segments = Self.composeChatSegments(messages)

        // Snapshots are cumulative, so each one is turned into the suffix the
        // UI hasn't seen. Guarded with `hasPrefix` rather than assumed: a
        // snapshot that isn't a superset of what we've already shown would
        // otherwise splice garbage into the middle of the reply.
        // Defence in depth for the gate in `ChatEngine.hotImageCap()`. If images
        // reach an engine that cannot attach them, the prompt has already told
        // the model they are "shown to you directly below" and they are not —
        // which produces a confident answer about a picture nobody sent. Logged
        // loudly rather than thrown: a degraded answer beats a failed turn, but
        // this must never happen quietly.
        if !Self.canAttachImages, messages.contains(where: { !$0.imagePaths.isEmpty }) {
            NSLog("[Dictator] Apple chat round was handed image(s) this build can't attach — the prompt will claim they are there. Fix the gate in ChatEngine.hotImageCap().")
        }

        var delivered = ""
        do {
            for try await snapshot in session.streamResponse(
                to: Self.prompt(from: segments), options: options
            ) {
                if Task.isCancelled { throw CancellationError() }
                let full = snapshot.content
                guard full.hasPrefix(delivered), full.count > delivered.count else { continue }
                let delta = String(full.dropFirst(delivered.count))
                delivered = full
                onDelta(.chunk(delta))
            }
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                throw NSError(domain: "Dictator", code: 5, userInfo: [
                    NSLocalizedDescriptionKey:
                        "This conversation is too long for Apple's on-device model. "
                        + "Start a new chat, or switch to an MLX model in Settings → Models."
                ])
            }
            throw error
        }

        // `cleanChatReply`, matching the MLX round — `clean` alone is the
        // dictation cleaner and doesn't strip a reasoning span.
        let text = LLMTextUtilities.cleanChatReply(delivered)
        let promptChars = segments.reduce(0) { total, segment in
            if case .text(let value) = segment { return total + value.count }
            return total
        }
        Self.recordTokenUsage(promptCharCount: instructions.count + promptChars,
                              responseCharCount: delivered.count)
        return ChatRoundResult(
            text: text,
            toolCalls: [],
            promptTokens: (instructions.count + promptChars) / 4,
            completionTokens: delivered.count / 4,
            // Apple doesn't say whether it stopped early, and the alternative
            // is guessing from a character-count estimate of the token cap —
            // which would mislabel long-but-complete replies as truncated.
            hitTokenLimit: false,
            // No speed either: `usage` is macOS 27-only (CI releases build on
            // the 26 SDK), and a rate derived from an estimated token count
            // divided by a real clock is the mismatched-population mistake the
            // usage pane has made before. Nil is a documented outcome.
            speed: nil
        )
    }

    /// One piece of the prompt: either prose, or a picture sitting where its own
    /// message sat.
    enum ChatSegment: Sendable {
        case text(String)
        case image(CGImage)
    }

    /// Builds the prompt from segments.
    ///
    /// Runs of text are joined so the model sees ordinary prose rather than a
    /// stack of fragments; an image interrupts the run and the next run starts
    /// after it. On a build or an OS without image support the images are simply
    /// absent, which is the same prompt the engine sent before any of this.
    private static func prompt(from segments: [ChatSegment]) -> Prompt {
        #if FOUNDATION_MODELS_VISION
        if #available(macOS 27.0, *) {
            return Prompt {
                for segment in segments {
                    switch segment {
                    case .text(let value): value
                    case .image(let image): Attachment(image)
                    }
                }
            }
        }
        #endif
        return Prompt(textOnly(segments))
    }

    private static func textOnly(_ segments: [ChatSegment]) -> String {
        segments.compactMap { segment -> String? in
            if case .text(let value) = segment { return value }
            return nil
        }.joined(separator: "\n\n")
    }

    /// Renders the wire messages as ordered prompt segments.
    ///
    /// The same inline approach `composeAssistantPrompt` takes, and for the same
    /// reason: Apple's session is multi-turn via its own `Transcript`, but
    /// `ChatEngine` owns the thread and re-sends it whole each round, so a session
    /// that also accumulated history would double it.
    ///
    /// The system message is dropped — it goes in as `Instructions`.
    private static func composeChatSegments(_ messages: [ChatWireMessage]) -> [ChatSegment] {
        var segments: [ChatSegment] = []
        var pending: [String] = []
        func flush() {
            guard !pending.isEmpty else { return }
            segments.append(.text(pending.joined(separator: "\n\n---\n\n")))
            pending = []
        }

        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                pending.append("User:\n\(message.content)")
            case .assistant:
                pending.append("Assistant:\n\(message.content)")
            case .tool:
                // Can't arise — this engine never emits a call to answer — but a
                // thread carried over from an MLX model can hold them, and dropping
                // one silently would leave the reply above it looking like it came
                // from nowhere.
                pending.append("Tool result (\(message.toolName ?? "tool")):\n\(message.content)")
            case .system:
                continue
            }
            // The picture goes in after the message that carried it, so anything
            // said afterwards reads as being about it.
            for path in message.imagePaths {
                guard let image = loadImage(at: path) else { continue }
                flush()
                segments.append(.image(image))
            }
        }
        flush()
        return segments
    }

    private static func loadImage(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

}
