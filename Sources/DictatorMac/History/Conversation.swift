import Foundation

/// What context Assistant Mode pulled in for a turn — surfaced in the result
/// window so the user can see, per turn, whether the text around the cursor and
/// the focused window were actually captured (and what they said) rather than
/// having to guess. Optional on the turn; older turns (and turns where nothing
/// was captured and vision wasn't tried) carry none.
struct CapturedContextInfo: Codable, Equatable, Hashable, Sendable {
    /// Document text read around the cursor via Accessibility (before + after),
    /// truncated for display.
    var documentText: String
    /// Why the Accessibility read came back without text, when it did (no
    /// focused field, focused on Dictator, field exposes no cursor…). Empty on
    /// success or when there was text. Shown in the banner.
    var documentNote: String = ""
    /// Distinctive terms merged from the Accessibility read and the vision pass
    /// (used as spelling references).
    var termCount: Int
    /// Whether window-vision actually ran for this turn — lets the UI tell
    /// "vision read nothing" apart from "vision was off".
    var visionAttempted: Bool
    /// The vision model's description of the focused window; empty when it read
    /// nothing or wasn't run.
    var visionDescription: String
    /// Why the vision read came back empty, when it did (timed out / couldn't
    /// capture / declined). Empty on success or when vision wasn't attempted.
    var visionNote: String = ""

    var hasDocumentText: Bool { !documentText.isEmpty }
    var hasVision: Bool { !visionDescription.isEmpty }
}

/// One round-trip in an Assistant Mode conversation, in the shape the *prompt*
/// is built from.
///
/// Not the shape it's stored in: threads persist as `ChatThread`/`ChatMessage`
/// whichever way in they came, and `ChatThread.assistantTurns` derives these on
/// demand. Keeping the payload type separate from the storage type is what let
/// Assistant Mode and the chat window share one store without either engine's
/// `assist` implementation changing — the same split `ChatWireMessage` makes on
/// the chat side.
struct ConversationTurn: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let instruction: String
    let selection: String?
    let mode: AssistantMode
    let reply: String
    /// Context captured for this turn, for display in the result window. `var`
    /// + default so the synthesised Codable decodes older persisted turns
    /// (missing key → nil) and existing call sites stay source-compatible.
    var context: CapturedContextInfo? = nil
}

/// Compaction state recorded once we've summarised the oldest turns to fit
/// inside the model's context window. `summary` stands in for everything up to
/// and including `upThroughTurnIndex`. The messages themselves stay in the
/// thread so the transcript can still show the whole conversation — only the
/// LLM payload uses the summary.
///
/// Indexes into `ChatThread.assistantTurns`, i.e. into the *turn pairs*, not
/// into `messages`.
struct ConversationCompaction: Codable, Equatable, Hashable, Sendable {
    let summary: String
    let upThroughTurnIndex: Int
    /// Chat threads cut at a *message*, not a turn pair.
    ///
    /// Assistant Mode compacts a list of `ConversationTurn`s, where an index is
    /// a perfectly good cut. The chat window's unit is `ChatMessage`, and its
    /// messages interleave tool calls and results that do not pair up into
    /// turns at all — so it stores the id of the last message the summary
    /// covers. An id rather than an index because a thread can gain messages at
    /// any time and an index would quietly come to mean something else.
    ///
    /// Optional, so it decodes from anything written before it existed. Exactly
    /// one of the two is meaningful per thread, decided by which entry point
    /// compacted it.
    var upThroughMessageID: UUID?

    init(summary: String, upThroughTurnIndex: Int, upThroughMessageID: UUID? = nil) {
        self.summary = summary
        self.upThroughTurnIndex = upThroughTurnIndex
        self.upThroughMessageID = upThroughMessageID
    }

    /// Hand-written for the same reason as `ChatMessage.init(from:)`: this type
    /// is nested inside `ChatThread`, so a decode failure here doesn't lose one
    /// field — `ChatStore.load` discards the whole file and quarantines it.
    /// That has already happened twice and stranded 38 conversations.
    ///
    /// `upThroughTurnIndex` is still *written* on every path, including the chat
    /// one, so a build that predates `upThroughMessageID` can decode anything
    /// this build writes. Two Macs sharing a synced folder can be on different
    /// versions, and the older one must not choke on the newer one's file.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        upThroughTurnIndex = try c.decodeIfPresent(Int.self, forKey: .upThroughTurnIndex) ?? -1
        upThroughMessageID = try c.decodeIfPresent(UUID.self, forKey: .upThroughMessageID)
    }
}

/// Token-budget heuristics used in two places: Pipeline decides when to
/// compact before calling the LLM, and the assistant window decides when to
/// surface an "approaching limit" warning chip. `ChatThread` wraps both.
///
/// The per-engine budget itself lives on `LLMEngine.assistantInputTokenBudget`
/// (MLX derives it from the model's native context window; Apple uses a
/// conservative fixed figure since the framework's context isn't exposed).
/// This enum carries the shared reservation constant and the cross-engine
/// token-counting helper.
enum ConversationContextBudget {
    /// Tokens we hold back from the model's native window for things that
    /// aren't conversation history. Sum:
    /// - 2K for the assistant system prompt (which is large by design)
    /// - 8K for the worst-case reply (`GenerateParameters.maxTokens` in
    ///   MLXLLMService.assist; almost no replies actually reach this)
    /// - 1K margin for chat-template role markers and tokenizer slop
    static let nonInputReservationTokens = 11_000

    /// Rough 4-chars-per-token approximation plus a small per-message overhead
    /// for chat-template tokens (role markers etc.). Not exact — exactness
    /// isn't required for a "approaching limit" warning.
    static func estimateInputTokens(
        priorTurns: [ConversationTurn],
        summary: String?,
        selection: String?,
        instruction: String,
        context: InsertionContext? = nil
    ) -> Int {
        var chars = (selection?.count ?? 0) + instruction.count
        if let context {
            chars += context.textBefore.count + context.textAfter.count
            chars += context.documentTerms.reduce(0) { $0 + $1.count + 2 }
            chars += context.screenContent.count
        }
        for turn in priorTurns {
            chars += turn.instruction.count + (turn.selection?.count ?? 0) + turn.reply.count
        }
        if let summary { chars += summary.count }
        let perMessageOverhead = 8
        let messageCount = priorTurns.count * 2 + 1 + (summary == nil ? 0 : 1)
        return chars / 4 + messageCount * perMessageOverhead
    }
}
