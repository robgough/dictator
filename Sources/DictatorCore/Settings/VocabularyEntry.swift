import Foundation

/// How a dictionary rule decides whether it applies to a span of transcript.
///
/// `literal` is the original (and default) behaviour — every rule written
/// before this existed decodes as literal, so nothing changes for anyone
/// until they opt a rule in.
enum VocabularyMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Exact text, respecting the entry's case-sensitive / whole-word flags.
    case literal
    /// Anything that *sounds* like the pattern — see `PhoneticKey`. Fixes the
    /// long tail of spellings an ASR engine invents for the same name without
    /// needing a rule per spelling.
    case phonetic
    /// The pattern is a regular expression and the replacement is a template,
    /// so `$1` and friends carry capture groups through.
    case regex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .literal:  "Exact"
        case .phonetic: "Sounds like"
        case .regex:    "Pattern"
        }
    }

    /// One line for the row's tooltip / picker help.
    var summary: String {
        switch self {
        case .literal:
            "Replaces this exact text."
        case .phonetic:
            "Replaces this text and anything that sounds like it — catches the spellings your model invents."
        case .regex:
            "The Heard field is a regular expression. Use $1 in the replacement for capture groups."
        }
    }

    /// Whether the case-sensitive and whole-word flags mean anything in this
    /// mode. Phonetic matching is inherently case- and boundary-insensitive
    /// (it compares sounds, word by word), so the row hides both toggles.
    var usesLiteralFlags: Bool { self != .phonetic }
}

extension VocabularyMatchMode {
    /// What a rule the user creates today starts as.
    ///
    /// Sounds-like rather than exact, because exact only ever fires when the
    /// model already got the word nearly right — which is precisely when you
    /// didn't need a rule. Safe as a default because sounds-like is a
    /// *superset* of exact: it matches the literal text too, and a pattern too
    /// short to key phonetically falls back to matching exactly rather than
    /// doing nothing.
    ///
    /// Rules saved before this existed decode as `.literal` and are left
    /// alone — silently broadening someone's existing dictionary would be a
    /// change they never asked for.
    static let defaultForNewRule: VocabularyMatchMode = .phonetic
}

struct VocabularyEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var pattern: String
    var replacement: String
    var caseSensitive: Bool
    var wholeWord: Bool
    /// Added after the literal-only era; every persisted entry without the key
    /// decodes as `.literal`, so existing dictionaries behave exactly as before.
    var matchMode: VocabularyMatchMode

    init(id: UUID = UUID(),
         pattern: String,
         replacement: String,
         caseSensitive: Bool = false,
         wholeWord: Bool = true,
         matchMode: VocabularyMatchMode = .literal) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.matchMode = matchMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, replacement, caseSensitive, wholeWord, matchMode
    }

    /// Hand-rolled so a blob written before `matchMode` existed — or by an
    /// older build sharing the same synced `vocabulary.json` — still decodes
    /// rather than throwing and taking the whole file's entries with it.
    ///
    /// It also carries the one-time upgrade of pre-match-mode rules to
    /// sounds-like. See `upgradedMatchMode`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true
        if let stored = try c.decodeIfPresent(VocabularyMatchMode.self, forKey: .matchMode) {
            matchMode = stored
        } else {
            matchMode = Self.upgradedMatchMode(caseSensitive: caseSensitive, wholeWord: wholeWord)
        }
    }

    /// What a rule written before match modes existed should become.
    ///
    /// Sounds-like is a superset of exact — it matches the literal text
    /// first — so upgrading an ordinary rule can only make it catch *more* of
    /// what its author wanted, which is the whole reason they wrote it. Rules
    /// stay exact in the two cases where the author asked for something
    /// sounds-like can't express:
    ///
    /// - **`caseSensitive`** — phonetic matching compares sounds, and sounds
    ///   have no casing. Upgrading would silently discard the distinction the
    ///   user deliberately switched on.
    /// - **`wholeWord == false`** — that's an explicit request to match
    ///   *inside* words, and phonetic matching works on whole words only. A
    ///   rule like "teh" → "the" set to match anywhere would quietly stop
    ///   firing.
    ///
    /// Only applies to blobs with no `matchMode` key at all. Once a rule has
    /// been written by this build it carries its mode explicitly, so someone
    /// who sets a rule back to Exact keeps it — this can't re-upgrade them on
    /// the next launch.
    static func upgradedMatchMode(caseSensitive: Bool, wholeWord: Bool) -> VocabularyMatchMode {
        (wholeWord && !caseSensitive) ? .defaultForNewRule : .literal
    }

    /// A rule that can't fire at all as written. Only a malformed regex
    /// qualifies — everything else still does *something*.
    var validationProblem: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, matchMode == .regex else { return nil }
        do {
            _ = try NSRegularExpression(pattern: trimmed)
            return nil
        } catch {
            return "Not a valid pattern — this rule won't do anything."
        }
    }

    /// Something worth knowing about the rule that isn't a fault. Currently
    /// just the one case: a phonetic pattern too short for Metaphone to key
    /// safely still matches its exact text, and the user should be told that
    /// rather than assuming sounds-like is working.
    var validationNote: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, matchMode == .phonetic else { return nil }
        guard PhoneticKey.normalizedLetters(trimmed).count < PhoneticKey.minPatternLetters else { return nil }
        return "Too short to match by sound (under \(PhoneticKey.minPatternLetters) letters) — matches exactly instead."
    }
}

enum Vocabulary {
    /// Apply the user's dictionary to `text`, in declaration order. Returns
    /// the original `text` unchanged when there's nothing to apply.
    ///
    /// Order matters and is the user's: entries run top to bottom, each seeing
    /// the output of the one before it, so a broad phonetic rule can be placed
    /// after the narrow literal rules that should win.
    static func apply(_ entries: [VocabularyEntry], to text: String) -> String {
        guard !entries.isEmpty, !text.isEmpty else { return text }
        var out = text
        for entry in entries {
            let pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            switch entry.matchMode {
            case .literal:
                out = applyRegex(pattern: NSRegularExpression.escapedPattern(for: pattern),
                                 template: NSRegularExpression.escapedTemplate(for: entry.replacement),
                                 entry: entry,
                                 to: out)
            case .regex:
                out = applyRegex(pattern: pattern,
                                 template: entry.replacement,
                                 entry: entry,
                                 to: out)
            case .phonetic:
                out = applyPhonetic(pattern: pattern, replacement: entry.replacement, entry: entry, to: out)
            }
        }
        return out
    }

    /// Shared body for the literal and regex modes — literal just escapes its
    /// pattern and template first.
    private static func applyRegex(pattern: String,
                                   template: String,
                                   entry: VocabularyEntry,
                                   literalWholeWord: Bool = false,
                                   to text: String) -> String {
        var regexPattern = pattern
        // Whole-word wrapping is only meaningful for a literal: bolting
        // boundaries onto a user's own regex would break alternations and
        // anchors they wrote deliberately. `literalWholeWord` is the
        // short-pattern phonetic fallback, which is word-based by nature.
        if literalWholeWord || (entry.wholeWord && entry.matchMode == .literal) {
            regexPattern = "(?<!\\w)\(regexPattern)(?!\\w)"
        }
        var options: NSRegularExpression.Options = []
        if !entry.caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Sound-alike replacement. Walks `text` word by word, testing every
    /// window the width of the pattern's own word count, and swaps whole
    /// windows that key the same (see `PhoneticKey.soundsLike`).
    ///
    /// Windows are only formed across "plain" separators — spaces, hyphens
    /// and apostrophes. A full stop or newline between two words means they
    /// belong to different utterances, and a two-word rule shouldn't reach
    /// across the boundary to join them.
    private static func applyPhonetic(pattern: String, replacement: String,
                                      entry: VocabularyEntry, to text: String) -> String {
        // Prepared once and reused for every window — see `PhoneticKey.Pattern`.
        let prepared = PhoneticKey.Pattern(pattern)
        // Too short (or too vowel-thin) to key safely. Fall back to an exact
        // whole-word replace rather than doing nothing: sounds-like is the
        // default for new rules, and a three-letter rule like "AWS" silently
        // never firing would be a trap.
        guard prepared.isUsable else {
            return applyRegex(pattern: NSRegularExpression.escapedPattern(for: pattern),
                              template: NSRegularExpression.escapedTemplate(for: entry.replacement),
                              entry: entry,
                              literalWholeWord: true,
                              to: text)
        }
        let span = prepared.wordCount

        let words = wordRanges(in: text)
        guard words.count >= span else { return text }

        var out = ""
        var cursor = text.startIndex
        var index = 0
        while index + span <= words.count {
            let first = words[index]
            let last = words[index + span - 1]

            // Reject the window if any gap inside it isn't a plain separator.
            var joinable = true
            if span > 1 {
                for step in index..<(index + span - 1) {
                    let gap = text[words[step].upperBound..<words[step + 1].lowerBound]
                    if !gap.allSatisfy(isPlainSeparator) {
                        joinable = false
                        break
                    }
                }
            }

            let candidateRange = first.lowerBound..<last.upperBound
            if joinable, prepared.matches(String(text[candidateRange])) {
                out += text[cursor..<first.lowerBound]
                out += replacement
                cursor = last.upperBound
                index += span
                continue
            }
            index += 1
        }
        guard cursor != text.startIndex else { return text }
        out += text[cursor...]
        return out
    }

    /// Separators a multi-word phonetic window may span. Anything else — a
    /// full stop, a comma, a newline — marks a boundary the rule shouldn't
    /// reach across.
    private static func isPlainSeparator(_ c: Character) -> Bool {
        switch c {
        case " ", "-", "'", "\u{2019}": return true
        default: return false
        }
    }

    /// Ranges of the word-like runs in `text`. Letters, digits and intra-word
    /// apostrophes count as word characters, so "O'Brien" and "v2" stay whole.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index? = nil
        var i = text.startIndex
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "'" || c == "\u{2019}"
        }
        while i < text.endIndex {
            if isWordChar(text[i]) {
                if start == nil { start = i }
            } else if let s = start {
                ranges.append(s..<i)
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }
}
