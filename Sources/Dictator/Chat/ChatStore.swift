import Foundation
import Observation

/// Persisted chat threads, in the user's synced folder alongside
/// `history.json` and `conversations.json`.
///
/// Retention differs from `ConversationHistory` on purpose. Assistant Mode
/// conversations are ephemeral by design — you say a thing, it pastes, you move
/// on — so they're capped at 20 entries / 14 days. A chat thread is a document:
/// people come back to them, and silently deleting one a fortnight later would
/// be a bug, not a tidy-up. So: a generous count cap, no age cap, and an
/// explicit "Delete" in the UI. Threads are plain text; 200 of them is a
/// couple of megabytes.
@MainActor
@Observable
final class ChatStore {
    static let shared = ChatStore()

    /// Newest first.
    private(set) var threads: [ChatThread] = []

    private static let maxThreads = 200

    private static var storeURL: URL {
        SyncedStorage.fileURL(for: "chats.json")
    }

    /// Coalesces the writes a streaming reply would otherwise cause. A chat
    /// round mutates the active thread on nearly every token; persisting each
    /// time would write the whole file hundreds of times per reply.
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        load()
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
