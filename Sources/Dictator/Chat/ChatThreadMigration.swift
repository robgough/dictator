import Foundation

/// Reads the Assistant Mode store as it was before the two stores merged.
///
/// Assistant Mode kept its conversations in `conversations.json` and the chat
/// window kept its threads in `chats.json`, until the two were recognised as
/// the same thing reached by different doors. This converts the former into the
/// latter, once, on the launch after the merge ships.
///
/// It lives apart from `ChatStore` — which owns the file moves and the dedupe —
/// so the conversion itself can be run outside the app. It is exactly the sort
/// of code that compiles perfectly and quietly drops half of someone's history,
/// and `scratch/chat-merge-check` round-trips it against a real archive.
enum LegacyConversationStore {
    /// Every conversation in `data` that isn't already in the store, as
    /// threads. `nil` when the file won't decode at all — which the caller
    /// must treat as "leave the file alone", not as "nothing to migrate".
    static func threads(
        fromConversationsJSON data: Data, skipping known: Set<UUID> = []
    ) -> [ChatThread]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let legacy = try? decoder.decode([LegacyConversation].self, from: data)
        else { return nil }
        return legacy.filter { !known.contains($0.id) }.map { $0.asThread() }
    }
}

/// `conversations.json` as it was written. Exists only to be read from.
///
/// `createdAt` isn't carried: the old store set it to the first turn's
/// timestamp, which is exactly what `ChatThread.assistant` derives, so nothing
/// is lost by leaving it out.
private struct LegacyConversation: Decodable {
    let id: UUID
    let updatedAt: Date
    let turns: [ConversationTurn]
    let compaction: ConversationCompaction?

    /// One conversation as a thread. The unfolding itself lives on
    /// `ChatThread.assistant(id:turns:compaction:)`, shared with the demo
    /// fixtures so there is only one account of what a turn becomes.
    ///
    /// `updatedAt` is taken from the old record rather than from the last turn,
    /// so a conversation's place in the list survives the move intact.
    func asThread() -> ChatThread {
        var thread = ChatThread.assistant(id: id, turns: turns, compaction: compaction)
        thread.updatedAt = updatedAt
        return thread
    }
}
