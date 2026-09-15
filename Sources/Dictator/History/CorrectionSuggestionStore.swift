import Foundation
import Observation

/// One "you fixed this by hand" observation, waiting for the user to decide
/// whether it's worth a permanent dictionary rule.
///
/// These are *suggestions only*. Nothing here ever changes a transcript — the
/// user has to accept one in Settings → Dictionary before it becomes a
/// `VocabularyEntry`. Guessing on the user's behalf is exactly the failure
/// mode that makes auto-correct hated.
struct CorrectionSuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// The word Dictator delivered.
    var heard: String
    /// What the user replaced it with.
    var corrected: String
    /// Bundle ID of the app the correction happened in — shown as context so
    /// "was this a one-off in a chat, or a name I always type?" is answerable.
    var appBundleID: String?
    /// How many separate dictations this same correction has been seen in.
    /// A repeat is much stronger evidence than a one-off, so the UI sorts on it.
    var seenCount: Int
    var firstSeen: Date
    var lastSeen: Date

    init(id: UUID = UUID(),
         heard: String,
         corrected: String,
         appBundleID: String?,
         seenCount: Int = 1,
         firstSeen: Date = Date(),
         lastSeen: Date = Date()) {
        self.id = id
        self.heard = heard
        self.corrected = corrected
        self.appBundleID = appBundleID
        self.seenCount = seenCount
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    /// Identity for de-duplication: the same pair seen again bumps `seenCount`
    /// rather than adding a second row.
    var dedupeKey: String {
        "\(heard.lowercased())\u{1F}\(corrected.lowercased())"
    }

    /// The rule this suggestion would become if accepted. Phonetic when the
    /// two spellings actually sound alike (so the rule also catches the *next*
    /// spelling the model invents); literal otherwise — a case fix like
    /// "github" → "GitHub" has no phonetic difference to generalise from.
    var proposedEntry: VocabularyEntry {
        let phonetic = PhoneticKey.soundsLike(candidate: heard, pattern: corrected)
            && PhoneticKey.normalizedLetters(heard) != PhoneticKey.normalizedLetters(corrected)
        return VocabularyEntry(
            pattern: heard,
            replacement: corrected,
            caseSensitive: false,
            wholeWord: true,
            matchMode: phonetic ? .phonetic : .literal
        )
    }
}

/// File-backed store for pending correction suggestions.
///
/// Lives in the Dictator target rather than `DictatorCore`: suggestions are
/// produced by `CorrectionWatcher`, which is Accessibility-based and therefore
/// macOS-only, and the store reaches for `SyncedStorage.fileURL(for:)` — an
/// AppKit-only convenience.
///
/// Deliberately simpler than `VocabularyStore`: no file watcher, no external
/// edit story, no recovery copies. This is a scratch list of hints that the
/// user either promotes into the real dictionary or dismisses — losing it
/// costs nothing, so it doesn't earn that machinery.
@MainActor
@Observable
final class CorrectionSuggestionStore {
    static let shared = CorrectionSuggestionStore()

    /// Strongest evidence first: most-repeated, then most recent.
    private(set) var suggestions: [CorrectionSuggestion] = []

    /// Hard cap. Suggestions are a nudge, not a backlog — past a couple of
    /// dozen the pane stops being scannable and the oldest single-sighting
    /// entries are the least useful anyway.
    private static let maxSuggestions = 24
    /// Suggestions this old are dropped on load. A correction you haven't
    /// acted on in a fortnight wasn't worth a rule.
    private static let maxAgeDays = 14

    private var loaded = false

    private init() {}

    private static var storeURL: URL {
        SyncedStorage.fileURL(for: "correction-suggestions.json")
    }

    /// Record a correction sighting. Existing pairs bump their count; new
    /// pairs are appended and the list re-sorted and trimmed.
    func record(heard: String, corrected: String, appBundleID: String?) {
        ensureLoaded()
        let candidate = CorrectionSuggestion(heard: heard, corrected: corrected, appBundleID: appBundleID)
        if let index = suggestions.firstIndex(where: { $0.dedupeKey == candidate.dedupeKey }) {
            suggestions[index].seenCount += 1
            suggestions[index].lastSeen = Date()
        } else {
            suggestions.append(candidate)
        }
        sortAndTrim()
        persist()
    }

    func remove(id: UUID) {
        ensureLoaded()
        suggestions.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        ensureLoaded()
        suggestions.removeAll()
        persist()
    }

    /// Drop any suggestion whose pair is already covered by a dictionary
    /// rule. Called after the user accepts one, and when the Dictionary pane
    /// appears, so a rule added by hand quietly retires the matching hint.
    func pruneCovered(by entries: [VocabularyEntry]) {
        ensureLoaded()
        guard !suggestions.isEmpty else { return }
        let before = suggestions.count
        suggestions.removeAll { suggestion in
            Vocabulary.apply(entries, to: suggestion.heard)
                .caseInsensitiveCompare(suggestion.corrected) == .orderedSame
        }
        if suggestions.count != before { persist() }
    }

    /// Load on first touch so a user who never enables the feature never pays
    /// for the read.
    func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard
            let data = try? Data(contentsOf: Self.storeURL),
            let decoded = try? JSONDecoder.suggestions.decode([CorrectionSuggestion].self, from: data)
        else { return }
        suggestions = decoded
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.maxAgeDays, to: Date()) ?? .distantPast
        suggestions.removeAll { $0.lastSeen < cutoff }
        sortAndTrim()
    }

    private func sortAndTrim() {
        suggestions.sort {
            if $0.seenCount != $1.seenCount { return $0.seenCount > $1.seenCount }
            return $0.lastSeen > $1.lastSeen
        }
        if suggestions.count > Self.maxSuggestions {
            suggestions = Array(suggestions.prefix(Self.maxSuggestions))
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder.suggestions.encode(suggestions) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}

private extension JSONDecoder {
    static let suggestions: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let suggestions: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
}
