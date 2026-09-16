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
        guard let data = try? Data(contentsOf: Self.storeURL) else {
            // No store yet — but there may still be a quarantined one to fold
            // back in, which is exactly the state a failed decode leaves behind.
            recoverQuarantinedThreads()
            return
        }
        do {
            // Element-wise, so one unreadable thread costs one thread. Decoding
            // `[ChatThread]` straight is all-or-nothing: the array decoder
            // rethrows, and the `catch` below then sets the *whole file* aside.
            // That is precisely how 38 conversations were stranded twice.
            let salvaged = try JSONDecoder.chatISO8601.decode([Lossy<ChatThread>].self, from: data)
            threads = salvaged.compactMap(\.value)
            let lost = salvaged.count - threads.count
            if lost > 0 {
                NSLog("[Dictator] %d chat(s) in chats.json wouldn't decode and were skipped; %d loaded.",
                      lost, threads.count)
            }
        } catch {
            // Keep the unreadable file rather than overwriting it on the next
            // save — same posture as DictatorSettings' corruption path. Losing
            // a dictation history is annoying; losing someone's chats is not.
            let backup = Self.storeURL.deletingLastPathComponent()
                .appendingPathComponent("chats.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
            NSLog("[Dictator] chats.json wouldn't decode (\(error)); kept a copy at \(backup.lastPathComponent)")
        }
        recoverQuarantinedThreads()
    }

    /// Fold back any threads stranded in a `chats.unreadable-*.json`.
    ///
    /// Those files are written by the `catch` above when the whole store fails
    /// to decode. Until the hand-written decoders on `ChatThread`,
    /// `ChatMessage` and `ChatAttachment` landed, one missing key was enough to
    /// do that: Swift's *synthesised* `init(from:)` ignores property defaults,
    /// so adding a non-optional defaulted field — `promoted` for the
    /// assistant/chat merge, `attachments` before it — made every previously
    /// written thread undecodable. It happened twice on 2026-09-15 and stranded
    /// 38 conversations.
    ///
    /// Those files decode now, so this reads them back. Strictly additive: a
    /// thread whose id is already present is skipped, so nothing live is ever
    /// overwritten by an older copy of itself. A file that still won't decode is
    /// left exactly where it is — recovery must never be the thing that loses
    /// the data. Handled files are renamed `chats.recovered-*.json` so this runs
    /// once per file and the originals remain on disk.
    private func recoverQuarantinedThreads() {
        let directory = Self.storeURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return }

        var known = Set(threads.map(\.id))
        var recovered: [ChatThread] = []
        var handled: [URL] = []
        for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.lastPathComponent.hasPrefix("chats.unreadable-")
            && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let salvaged = (try? JSONDecoder.chatISO8601.decode([Lossy<ChatThread>].self, from: data))?
                .compactMap(\.value)
            else {
                NSLog("[Dictator] %@ still won't decode — leaving it alone.",
                      url.lastPathComponent)
                continue
            }
            for thread in salvaged where !known.contains(thread.id) && !thread.isEmpty {
                known.insert(thread.id)
                var restored = thread
                // Exempt from the 14-day assistant sweep, which `prune()` runs
                // moments after this. 24 of the 38 stranded threads are
                // assistant-origin and only 3 were promoted, so without this a
                // launch after they age out would restore them and delete them
                // in the same breath — with the quarantine file already renamed.
                // The sweep is there to clear one-off dictations nobody returned
                // to; a conversation being handed back after being lost is not
                // that, and `promoted` already means "worth keeping".
                restored.promoted = true
                recovered.append(restored)
            }
            handled.append(url)
        }

        guard !recovered.isEmpty else { return }
        threads.append(contentsOf: recovered)
        threads.sort { $0.updatedAt > $1.updatedAt }

        // Written synchronously, and the quarantine files are renamed only once
        // that write has landed. `scheduleSave` debounces by 600ms, and this
        // runs from `init` — the window in which a crash, a kill, or the
        // second-instance guard can take the process out. Renaming first and
        // saving later would leave the threads in a file nothing reads again:
        // recovery itself becomes the thing that hides the data.
        guard persist() else {
            NSLog("[Dictator] Recovered %d chat(s) but couldn't save — leaving the quarantined files where they are, to try again next launch.",
                  recovered.count)
            return
        }
        for url in handled {
            let renamed = directory.appendingPathComponent(
                url.lastPathComponent.replacingOccurrences(
                    of: "chats.unreadable-", with: "chats.recovered-"))
            try? FileManager.default.moveItem(at: url, to: renamed)
        }
        NSLog("[Dictator] Recovered %d chat(s) from quarantined stores.", recovered.count)
    }

    @discardableResult
    private func persist() -> Bool {
        guard let data = try? JSONEncoder.chatISO8601.encode(threads) else { return false }
        do {
            try data.write(to: Self.storeURL, options: .atomic)
            return true
        } catch {
            NSLog("[Dictator] Couldn't write chats.json: %@", error.localizedDescription)
            return false
        }
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

/// Decodes what it can and swallows what it can't.
///
/// Wrapping each element means a decode failure is scoped to that element
/// instead of the array. For a store of conversations that is the difference
/// between losing one and losing all of them — the failure mode that has
/// already cost 38, twice, when a newly added field made every older record
/// unreadable at once.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
