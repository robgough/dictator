import Foundation

/// One round-trip in an Assistant Mode conversation: the user's spoken
/// instruction (plus any selection that was active at the time) and the
/// model's reply with its self-classified delivery mode.
struct ConversationTurn: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let instruction: String
    let selection: String?
    let mode: AssistantMode
    let reply: String
}

/// Compaction state recorded once we've summarised the oldest turns to fit
/// inside the model's context window. `summary` stands in for everything
/// `turns[0...upThroughTurnIndex]` said. The turns themselves stay in the
/// struct so the result window can still show the full chat history — only
/// the LLM payload uses the summary.
struct ConversationCompaction: Codable, Equatable, Hashable, Sendable {
    let summary: String
    let upThroughTurnIndex: Int
}

struct Conversation: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var turns: [ConversationTurn]
    var compaction: ConversationCompaction?

    /// The first instruction makes a decent default title for menu rows.
    var title: String {
        turns.first?.instruction ?? "Empty conversation"
    }

    var lastReply: String? { turns.last?.reply }

    static func new(firstTurn: ConversationTurn) -> Conversation {
        Conversation(
            id: UUID(),
            createdAt: firstTurn.timestamp,
            updatedAt: firstTurn.timestamp,
            turns: [firstTurn],
            compaction: nil
        )
    }

    mutating func append(_ turn: ConversationTurn) {
        turns.append(turn)
        updatedAt = turn.timestamp
    }
}

/// Token-budget heuristics used in two places: Pipeline decides when to
/// compact before calling the LLM, and the result window decides when to
/// surface an "approaching limit" warning chip. Kept in one struct so both
/// stay in lockstep.
///
/// Budget is computed from the active model's native context (see
/// `LLMModel.contextWindowTokens`) minus a fixed reservation for the
/// assistant system prompt, the worst-case reply, and a small margin for
/// chat-template overhead. That gives a per-model number — Llama 3.2's 128K
/// produces a ~117K input budget; Qwen 2.5's 32K produces ~21K.
enum ConversationContextBudget {
    /// Tokens we hold back from the model's native window for things that
    /// aren't conversation history. Sum:
    /// - 2K for the assistant system prompt (which is large by design)
    /// - 8K for the worst-case reply (`GenerateParameters.maxTokens` in
    ///   LLMService.assist; almost no replies actually reach this)
    /// - 1K margin for chat-template role markers and tokenizer slop
    static let nonInputReservationTokens = 11_000

    /// Per-conversation input budget for `modelID`. Exceeding this triggers
    /// pre-call compaction in Pipeline (the oldest turns get summarised so
    /// the rest still fit). Falls back to a 32K-sized budget when `modelID`
    /// isn't recognised so a hand-edited settings file can't blow up.
    static func totalInputTokens(modelID: String) -> Int {
        let context = ModelCatalog.llm(id: modelID)?.contextWindowTokens
            ?? ModelCatalog.fallbackContextWindowTokens
        return max(2_000, context - nonInputReservationTokens)
    }

    /// 80% of the per-model input budget — when the result window crosses
    /// this, we show the "approaching context limit" chip so the user
    /// knows the next turn may force a compaction summarisation.
    static func approachingThreshold(modelID: String) -> Int {
        totalInputTokens(modelID: modelID) * 4 / 5
    }

    /// Rough 4-chars-per-token approximation plus a small per-message overhead
    /// for chat-template tokens (role markers etc.). Not exact — exactness
    /// isn't required for a "approaching limit" warning.
    static func estimateInputTokens(
        priorTurns: [ConversationTurn],
        summary: String?,
        selection: String?,
        instruction: String
    ) -> Int {
        var chars = (selection?.count ?? 0) + instruction.count
        for turn in priorTurns {
            chars += turn.instruction.count + (turn.selection?.count ?? 0) + turn.reply.count
        }
        if let summary { chars += summary.count }
        let perMessageOverhead = 8
        let messageCount = priorTurns.count * 2 + 1 + (summary == nil ? 0 : 1)
        return chars / 4 + messageCount * perMessageOverhead
    }
}

extension Conversation {
    /// What the next assistant call would cost, ignoring the new instruction
    /// (which we don't know yet at render time). Used by the window to show an
    /// "approaching context limit" chip.
    var estimatedInputTokensForNextTurn: Int {
        let summary = compaction?.summary
        let activeTurns: [ConversationTurn]
        if let comp = compaction {
            activeTurns = Array(turns.dropFirst(comp.upThroughTurnIndex + 1))
        } else {
            activeTurns = turns
        }
        return ConversationContextBudget.estimateInputTokens(
            priorTurns: activeTurns,
            summary: summary,
            selection: nil,
            instruction: ""
        )
    }

    func isApproachingContextLimit(modelID: String) -> Bool {
        estimatedInputTokensForNextTurn >= ConversationContextBudget.approachingThreshold(modelID: modelID)
    }
}
