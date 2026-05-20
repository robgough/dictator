import Foundation
import Observation

/// Persisted list of Assistant Mode conversations, mirroring the shape of
/// DictationHistory. Lives alongside `history.json` in the user's synced
/// folder so threads continue seamlessly across Macs that share it.
/// Conversations are short by design (the user told us so), so keep a small
/// cap rather than the 500-deep dictation history.
@MainActor
@Observable
final class ConversationHistory {
    static let shared = ConversationHistory()

    /// Newest first.
    private(set) var conversations: [Conversation] = []

    private static let maxAgeDays = 14
    private static let maxEntries = 20

    private static var storeURL: URL {
        SyncedStorage.fileURL(for: "conversations.json")
    }

    private init() {
        load()
        prune()
    }

    /// Insert a fresh conversation at the top. Used for the first turn of a
    /// new conversation only.
    func append(_ conversation: Conversation) {
        conversations.insert(conversation, at: 0)
        prune()
        persist()
    }

    /// Replace an existing conversation in place (same id), keeping it at the
    /// top of the list since it was just updated. Used when a follow-up turn
    /// is appended to an active conversation.
    func update(_ conversation: Conversation) {
        conversations.removeAll(where: { $0.id == conversation.id })
        conversations.insert(conversation, at: 0)
        prune()
        persist()
    }

    func remove(id: UUID) {
        conversations.removeAll(where: { $0.id == id })
        persist()
    }

    func clear() {
        conversations.removeAll()
        persist()
    }

    func mostRecent(_ count: Int) -> [Conversation] {
        Array(conversations.prefix(count))
    }

    func conversation(id: UUID) -> Conversation? {
        conversations.first(where: { $0.id == id })
    }

    // MARK: - Pruning + persistence

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.maxAgeDays, to: Date()) ?? Date.distantPast
        conversations.removeAll { $0.updatedAt < cutoff }
        if conversations.count > Self.maxEntries {
            conversations = Array(conversations.prefix(Self.maxEntries))
        }
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: Self.storeURL),
            let decoded = try? JSONDecoder.iso8601.decode([Conversation].self, from: data)
        else { return }
        conversations = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso8601.encode(conversations) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
