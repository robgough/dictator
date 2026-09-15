import Foundation
import Observation

/// Every conversation with the local model, however it started — the chat
/// window or the Assistant hotkey. One store, in the user's synced folder
/// alongside `history.json`.
///
/// Retention still differs by origin, because the two habits differ. An
/// Assistant Mode turn is usually disposable — you say a thing, it pastes into
/// Mail, you move on — so assistant threads are swept after 14 days. A chat
/// thread is a document: people come back to them, and silently deleting one a
/// fortnight later would be a bug rather than a tidy-up, so those have a count
/// cap and no age cap at all.
///
/// The exception is `promoted`: opening an assistant thread in the chat window
/// is the user saying it *is* a document, and it stops being swept from that
/// moment. Threads are plain text, so 200 of them is a couple of megabytes.
@MainActor
@Observable
final class ChatStore {
    static let shared = ChatStore()

    /// Newest first.
    private(set) var threads: [ChatThread] = []

    private static let maxThreads = 200
    /// How long an un-promoted assistant thread survives. Matches what
    /// `ConversationHistory` used before the two stores merged, so nobody's
    /// existing threads change lifetime on the day of the migration.
    private static let assistantMaxAgeDays = 14

    private static var storeURL: URL {
        SyncedStorage.fileURL(for: "chats.json")
    }

    /// The old Assistant Mode store. Read once, then renamed aside.
    private static var legacyConversationsURL: URL {
        SyncedStorage.fileURL(for: "conversations.json")
    }

    /// Coalesces the writes a streaming reply would otherwise cause. A chat
    /// round mutates the active thread on nearly every token; persisting each
    /// time would write the whole file hundreds of times per reply.
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        load()
        migrateLegacyConversations()
        prune()
    }

    func thread(id: UUID) -> ChatThread? {
        threads.first(where: { $0.id == id })
    }

    /// Inserts or replaces, keeping the list newest-first.
    func upsert(_ thread: ChatThread) {
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads.remove(at: index)
        }
        threads.insert(thread, at: 0)
        if threads.count > Self.maxThreads {
            threads = Array(threads.prefix(Self.maxThreads))
        }
        scheduleSave()
    }

    /// Marks a thread as something the user has decided to keep. Called when an
    /// assistant thread is opened in the chat window — see `ChatThread.promoted`.
    func promote(id: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == id }),
              !threads[index].promoted
        else { return }
        threads[index].promoted = true
        scheduleSave()
    }

    func remove(id: UUID) {
        threads.removeAll(where: { $0.id == id })
        scheduleSave()
    }

    func removeAll() {
        threads.removeAll()
        scheduleSave()
    }

    /// Drops threads that were started and never used, so abandoning a "New
    /// chat" doesn't leave a row behind.
    func pruneEmpty(keeping keepID: UUID?) {
        let before = threads.count
        threads.removeAll { $0.isEmpty && $0.id != keepID }
        if threads.count != before { scheduleSave() }
    }

    /// Flush anything still inside the debounce — called on quit, the same way
    /// the Scratchpad flushes its autosave.
    ///
    /// Only writes when a save was actually pending. Quitting touches
    /// `ChatStore.shared`, which constructs it; an unconditional write would
    /// then create a `chats.json` full of nothing for every user who has never
    /// opened the chat window.
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        persist()
    }

    // MARK: - Retention

    /// Sweeps assistant threads the user never promoted. Chat threads are never
    /// swept by age — only by the count cap in `upsert`.
    private func prune() {
        let cutoff = Calendar.current.date(
            byAdding: .day, value: -Self.assistantMaxAgeDays, to: Date()) ?? .distantPast
        let before = threads.count
        threads.removeAll { thread in
            thread.origin == .assistant && !thread.promoted && thread.updatedAt < cutoff
        }
        if threads.count != before { scheduleSave() }
    }

    // MARK: - Migration

    /// Folds the old `conversations.json` into this store, once.
    ///
    /// Assistant Mode and the chat window kept separate stores until they were
    /// recognised as the same thing with different entry points. Each old
    /// conversation becomes one `.assistant` thread whose turns unfold into
    /// user/assistant message pairs — which is what they always were.
    ///
    /// The old file is renamed rather than deleted. It is the only copy of
    /// these conversations, the conversion is lossless but not obviously so,
    /// and a rename costs nothing next to being wrong about that.
    private func migrateLegacyConversations() {
        let source = Self.legacyConversationsURL
        guard FileManager.default.fileExists(atPath: source.path),
              let data = try? Data(contentsOf: source)
        else { return }

        // Ids carry over, so re-running this can't duplicate anything even if
        // the rename below failed last time.
        guard let migrated = LegacyConversationStore.threads(
            fromConversationsJSON: data, skipping: Set(threads.map(\.id)))
        else {
            NSLog("[Dictator] conversations.json wouldn't decode; left it in place unmigrated")
            return
        }

        if !migrated.isEmpty {
            threads.append(contentsOf: migrated)
            threads.sort { $0.updatedAt > $1.updatedAt }
            scheduleSave()
        }

        let archived = source.deletingLastPathComponent()
            .appendingPathComponent("conversations.migrated.json")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: source, to: archived)
        NSLog("[Dictator] Merged \(migrated.count) assistant conversation(s) into chats.json")
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.persist()
            self?.saveTask = nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        do {
            threads = try JSONDecoder.chatISO8601.decode([ChatThread].self, from: data)
        } catch {
            // Keep the unreadable file rather than overwriting it on the next
            // save — same posture as DictatorSettings' corruption path. Losing
            // a dictation history is annoying; losing someone's chats is not.
            let backup = Self.storeURL.deletingLastPathComponent()
                .appendingPathComponent("chats.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            NSLog("[Dictator] chats.json wouldn't decode (\(error)); kept a copy at \(backup.lastPathComponent)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder.chatISO8601.encode(threads) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let chatISO8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let chatISO8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
