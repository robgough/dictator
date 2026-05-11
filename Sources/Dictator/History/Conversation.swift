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
/// The numbers are conservative — they assume an 8K-context model and leave
/// headroom for the system prompt, the new selection+instruction, and the
/// reply. If the user later swaps to a larger-context model we can wire
/// this to the model catalog, but the user said conversations stay short
/// in practice so this is enough.
enum ConversationContextBudget {
    static let totalInputTokens = 4000
    static let approachingThreshold = 3200 // 80% of total

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

    var isApproachingContextLimit: Bool {
        estimatedInputTokensForNextTurn >= ConversationContextBudget.approachingThreshold
    }
}
