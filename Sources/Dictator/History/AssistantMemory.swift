import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Long-term memory for Assistant Mode: a short list of things the user has
/// told the assistant about themselves or how they want things done, folded
/// into the assistant system prompt on every turn.
///
/// Deliberately a plain markdown file (`assistant-memory.md`) rather than JSON,
/// living alongside `history.json` / `conversations.json` in the user's synced
/// folder. Two reasons:
///
/// - It follows the user between Macs, like everything else in that folder.
/// - It's the one store a user will actually want to *read and edit by hand*.
///   Memory that silently accumulates and can't be inspected is memory people
///   stop trusting. One bullet per line, a date, a sentence — openable in any
///   text editor, deletable a line at a time.
///
/// Because the file is hand-editable, the store re-reads whenever the file's
/// modification date has moved since the last read; there is no in-memory
/// state that can go stale behind the user's back.
///
/// Format:
/// ```
/// <!-- comment header -->
///
/// - 2026-09-06: Prefers British spelling.
/// - 2026-09-06: Signs off "Cheers", not "Best".
/// ```
/// Oldest first, newest appended at the end.
@MainActor
@Observable
final class AssistantMemory {
    static let shared = AssistantMemory()

    static let filename = "assistant-memory.md"

    /// Long enough for a real preference sentence, short enough that a model
    /// that starts summarising the whole task into the REMEMBER line gets
    /// truncated rather than poisoning the store.
    nonisolated static let maxEntryLength = 240

    /// The prompt block is capped by characters, not entries, so this is only
    /// a backstop against the file growing without bound.
    static let maxEntries = 200

    private static let fileHeader =
        "<!-- Dictator — things the assistant remembers about you. One bullet per line: `- YYYY-MM-DD: fact`. Edit or delete lines freely; the app picks up changes automatically. -->"

    /// Bumped on every mutation so `@Observable` views (the Assistant pane's
    /// "N remembered" row) redraw. `entries` reads it to register the
    /// dependency. Reloads triggered from a read never touch it — mutating
    /// observed state during a SwiftUI body evaluation is exactly the loop we
    /// don't want — which is why the cache below is observation-ignored.
    private var generation = 0

    @ObservationIgnored private var cache: [Item] = []
    @ObservationIgnored private var cacheStamp: Date?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let urlProvider: @MainActor () -> URL

    /// `urlProvider` is a closure rather than a stored URL for the same reason
    /// `ConversationHistory` recomputes its store URL on every access: the
    /// user can relocate the synced folder at any time and every store has to
    /// pick that up on its next read or write.
    init(urlProvider: @escaping @MainActor () -> URL = {
        SyncedStorage.fileURL(for: AssistantMemory.filename)
    }) {
        self.urlProvider = urlProvider
    }

    /// One remembered fact plus the day it was learned. Internal rather than
    /// private so the standalone check under `scratch/` can drive `parse`.
    struct Item: Equatable {
        var date: String
        var text: String
    }

    var fileURL: URL { urlProvider() }

    /// The remembered facts, oldest first. Re-reads from disk if the file has
    /// changed since the last read.
    var entries: [String] {
        _ = generation
        reloadIfNeeded()
        return cache.map(\.text)
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Force a re-read and notify observers. Called from the Settings pane on
    /// appear so a file the user edited in another app shows the right count.
    func refresh() {
        let before = cache.map(\.text)
        reloadIfNeeded(force: true)
        if cache.map(\.text) != before { generation &+= 1 }
    }

    // MARK: - Mutation

    /// Store one fact. Returns false when there was nothing to store or the
    /// fact is already known (case-insensitively) — the caller uses that to
    /// decide whether to say "Remembered" in the HUD.
    @discardableResult
    func remember(_ raw: String) -> Bool {
        let text = Self.normalise(raw)
        guard !text.isEmpty else { return false }
        reloadIfNeeded()
        guard !cache.contains(where: { $0.text.compare(text, options: .caseInsensitive) == .orderedSame })
        else { return false }
        cache.append(Item(date: Self.today(), text: text))
        if cache.count > Self.maxEntries {
            cache.removeFirst(cache.count - Self.maxEntries)
        }
        write()
        generation &+= 1
        return true
    }

    /// Empty the store. The file itself stays (with its header comment) so the
    /// user can still find and edit it after a reset.
    func forgetAll() {
        cache = []
        write()
        generation &+= 1
    }

    /// Reveal the file in the user's default markdown/text editor, creating it
    /// first if it doesn't exist yet — opening a path that isn't there just
    /// fails silently in Finder.
    func openInEditor() {
#if canImport(AppKit)
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            reloadIfNeeded()
            write()
        }
        NSWorkspace.shared.open(url)
#endif
    }

    // MARK: - Prompt

    /// The MEMORY block appended to the assistant system prompt, or nil when
    /// there's nothing to say. Newest entries are kept: when the block would
    /// exceed `maxChars` the oldest are dropped, so a long-lived store degrades
    /// into "the most recent things you told me" rather than "the first things".
    func promptBlock(maxChars: Int = 2000) -> String? {
        reloadIfNeeded()
        let texts = cache.map(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }

        let header = "MEMORY — things the user has told you before. Some are about them, some are about what they want from you (a name to answer to, a tone to keep). Use them when relevant; never recite them unprompted:"
        var kept: [String] = []
        var used = header.count
        for text in texts.reversed() {
            let cost = text.count + 3  // "\n- "
            if !kept.isEmpty, used + cost > maxChars { break }
            used += cost
            kept.insert(text, at: 0)
        }
        return header + kept.map { "\n- \($0)" }.joined()
    }

    // MARK: - Spoken "remember that…" detector

    /// The command itself. Within a family the longer form comes first so
    /// `remember that …` wins over `remember …` and the remainder doesn't
    /// keep a dangling "that".
    private nonisolated static let commandPrefixes = [
        "for future reference",
        "add to your memory that", "add to your memory",
        "add to memory that", "add to memory",
        "keep in mind that", "keep in mind",
        "bear in mind that", "bear in mind",
        "don't forget that", "don't forget",
        "do not forget that", "do not forget",
        "make a note that",
        "note down that",
        "memorise that", "memorize that",
        "remember that", "remember",
        "from now on",
        "note that"
    ]

    /// What people say *before* the command when they're talking to someone
    /// rather than issuing an order — "Hey, can you please remember that…".
    /// Peeled off, as many as it takes, before the command is matched. Each
    /// has to end on a word boundary, so "hide" isn't "hi" and "sort" isn't
    /// "so".
    private nonisolated static let leadIns = [
        "can you please", "could you please", "would you please", "will you please",
        "can you", "could you", "would you", "will you",
        "i want you to", "i'd like you to", "i need you to",
        "please", "hey", "hi", "hello", "okay", "ok", "so", "also", "and",
        "right", "well", "now", "just", "actually", "oh", "um", "uh"
    ]

    /// Punctuation and space that can sit between lead-ins and the command —
    /// "Okay, so… remember that". Stripped from the front only; a trailing
    /// full stop belongs to the fact.
    private nonisolated static let leadingNoise = CharacterSet(charactersIn: ",.!;:-—– \t\n\r")

    /// Recognises a spoken instruction that is *only* an instruction to
    /// remember something, and returns the thing to remember.
    ///
    /// This exists so "remember that I always sign off Cheers" doesn't have to
    /// round-trip through a small local model that will, more often than not,
    /// helpfully draft an email about remembering things. Deterministic
    /// prefix match, no LLM, no output pasted anywhere.
    ///
    /// Tolerates how the command actually gets said: lead-ins ("hey, can you
    /// …"), a name up front ("Mary, remember that …"), and the question mark
    /// a "can you …?" framing leaves on the end.
    nonisolated static func rememberCommand(in instruction: String) -> String? {
        var s = Substring(instruction)
        // Bounded: every pass consumes at least one character, and nobody
        // stacks eight lead-ins.
        for _ in 0..<8 {
            s = s.drop(while: { $0.unicodeScalars.allSatisfy(leadingNoise.contains) })
            guard !s.isEmpty else { return nil }
            let lower = s.lowercased().replacingOccurrences(of: "’", with: "'")

            if let prefix = commandPrefixes.first(where: { startsWithWord(lower, $0) }) {
                var fact = normalise(String(s.dropFirst(prefix.count)))
                // "Can you remember that X?" — the question mark belongs to
                // the asking, not the fact.
                while fact.hasSuffix("?") {
                    fact = String(fact.dropLast()).trimmingCharacters(in: .whitespaces)
                }
                guard !fact.isEmpty else { return nil }
                return capitalisingFirst(fact)
            }
            if let leadIn = leadIns.first(where: { startsWithWord(lower, $0) }) {
                s = s.dropFirst(leadIn.count)
                continue
            }
            if let name = vocativeLength(of: s) {
                s = s.dropFirst(name)
                continue
            }
            return nil
        }
        return nil
    }

    /// `text` starts with `word` and the match ends on a word boundary —
    /// "remembering the meeting" is not a memory command.
    private nonisolated static func startsWithWord(_ text: String, _ word: String) -> Bool {
        guard text.hasPrefix(word) else { return false }
        guard let next = text.dropFirst(word.count).first else { return true }
        return !(next.isLetter || next.isNumber)
    }

    /// Length of a single name followed by a comma at the front of `s`
    /// ("Mary, remember that …"), or nil. One word of letters only, so it
    /// can't swallow anything that isn't obviously someone being addressed.
    private nonisolated static func vocativeLength(of s: Substring) -> Int? {
        let word = s.prefix(while: { $0.isLetter })
        guard !word.isEmpty, word.count <= 24, s.dropFirst(word.count).first == "," else { return nil }
        return word.count
    }

    // MARK: - Text normalisation

    /// Trim, collapse all runs of whitespace (spoken instructions arrive as one
    /// line, but a hand-edited file or a chatty model won't), drop leading
    /// bullet/punctuation noise and a leading `REMEMBER:` marker, then cap the
    /// length.
    nonisolated static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.uppercased().hasPrefix("REMEMBER:") {
            s = String(s.dropFirst("REMEMBER:".count))
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-*•,;: \t"))
        if s.count > maxEntryLength {
            s = String(s.prefix(maxEntryLength)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private nonisolated static func capitalisingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    // MARK: - File I/O

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func today() -> String {
        dateFormatter.string(from: Date())
    }

    /// Re-read when the file's modification date has moved (or we've never
    /// read it). Touches no observed state, so it's safe to call from a
    /// SwiftUI body via `entries`.
    private func reloadIfNeeded(force: Bool = false) {
        let url = fileURL
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if !force, hasLoaded, stamp == cacheStamp { return }
        hasLoaded = true
        cacheStamp = stamp
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            cache = []
            return
        }
        cache = Self.parse(text)
    }

    /// Parses the markdown file. Anything that isn't a `- ` bullet (the header
    /// comment, blank lines, a stray note the user typed) is ignored rather
    /// than treated as an entry.
    nonisolated static func parse(_ text: String) -> [Item] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine -> Item? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { return nil }
            let body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            // `YYYY-MM-DD: rest` — the date is optional so a hand-written
            // "- always use British spelling" still counts as an entry.
            if body.count > 11, body.dropFirst(10).hasPrefix(":") {
                let date = String(body.prefix(10))
                if date.allSatisfy({ $0.isNumber || $0 == "-" }) {
                    let rest = String(body.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { return Item(date: date, text: rest) }
                }
            }
            return Item(date: "", text: body)
        }
    }

    private func write() {
        var lines = [Self.fileHeader, ""]
        for item in cache {
            let date = item.date.isEmpty ? Self.today() : item.date
            lines.append("- \(date): \(item.text)")
        }
        let body = lines.joined(separator: "\n") + "\n"
        let url = fileURL
        try? body.write(to: url, atomically: true, encoding: .utf8)
        cacheStamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        hasLoaded = true
    }
}
