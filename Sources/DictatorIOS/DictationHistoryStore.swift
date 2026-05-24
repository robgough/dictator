import Foundation
import Observation

/// One entry in the iOS prototype's dictation history. Deliberately
/// slimmer than the macOS `DictationRecord` because the iOS pipeline
/// doesn't (yet) run the multi-pass LLM chain — there's nothing
/// meaningful to record beyond what we ended up with.
struct DictationHistoryEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    /// The version delivered to the user / copied to the clipboard
    /// (post-cleanup if the Foundation tidy pass ran).
    let text: String
    /// Parakeet's raw output, before any deterministic or LLM passes.
    /// Optional so entries written before this field was introduced
    /// decode cleanly via `decodeIfPresent`. nil means "raw is the same
    /// as `text` — no extra version to show".
    let raw: String?

    /// True when we have a distinct pre-pass version worth surfacing
    /// in the UI (raw differs meaningfully from final).
    var hasRaw: Bool {
        guard let raw, raw != text else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Local, sandbox-private history for the iOS prototype. Mirrors the
/// macOS `DictationHistory` policy: 7-day rolling window, 500-entry cap,
/// JSON at-rest in the app's Application Support directory.
///
/// Stored under the app sandbox specifically (not the documents folder)
/// because the user has no reason to see this file in Files.app — it's
/// internal state, not user-curated content. When the keyboard extension
/// arrives this'll move into the App Group container so both targets see
/// the same history.
@MainActor
@Observable
final class DictationHistoryStore {
    static let shared = DictationHistoryStore()

    /// Newest first.
    private(set) var entries: [DictationHistoryEntry] = []

    private static let maxAgeDays = 7
    private static let maxEntries = 500

    private static var storeURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Dictator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private init() {
        load()
        prune()
    }

    /// Record the result of a successful transcription. Whitespace-only
    /// final text is dropped — preserves the "no dead rows" invariant
    /// the history list relies on for the empty-state check. `raw`
    /// optionally captures Parakeet's output before any post-processing
    /// so the history detail can show "what I actually heard you say"
    /// alongside the polished delivered version.
    func append(_ text: String, raw: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = DictationHistoryEntry(
            id: UUID(),
            timestamp: Date(),
            text: trimmed,
            raw: raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        entries.insert(entry, at: 0)
        prune()
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll(where: { $0.id == id })
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    // MARK: - Pruning + persistence

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.maxAgeDays, to: Date()) ?? Date.distantPast
        entries.removeAll { $0.timestamp < cutoff }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([DictationHistoryEntry].self, from: data)) ?? []
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
