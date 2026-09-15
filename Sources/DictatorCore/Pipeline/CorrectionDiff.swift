import Foundation

/// Works out which single words the user hand-corrected after a dictation
/// landed, by comparing the field's text just after the paste against the same
/// field a little later.
///
/// All the fiddly parts are pure string work so they can be reasoned about (and
/// exercised) without an Accessibility permission anywhere near them —
/// `CorrectionWatcher` owns the AX reads and hands the two snapshots here.
enum CorrectionDiff {

    /// One word swapped for another.
    struct Change: Equatable {
        let heard: String
        let corrected: String
    }

    /// How much text either side of the dictation is used to re-locate it in
    /// the later snapshot. Long enough to be unique in a normal document,
    /// short enough that editing nearby text doesn't destroy the anchor.
    private static let anchorChars = 48

    /// At most this many corrections are taken from one dictation. Somebody
    /// rewriting four words didn't correct a mis-hearing, they changed their
    /// mind — and treating that as dictionary evidence would poison the list.
    static let maxChangesPerDictation = 3

    /// Compare the field before and after the user's edits and return the
    /// word-for-word substitutions inside the region we pasted into.
    ///
    /// Returns an empty array whenever anything is ambiguous: the delivered
    /// text can't be found, the anchors have gone, the region grew wildly, or
    /// the edit isn't shaped like a correction.
    static func changes(fieldAfterPaste before: String,
                        fieldNow after: String,
                        delivered: String) -> [Change] {
        let needle = delivered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, before != after else { return [] }
        guard let deliveredRange = before.range(of: needle) else { return [] }

        // Anchor on the untouched text either side of what we pasted.
        let prefix = String(before[..<deliveredRange.lowerBound].suffix(anchorChars))
        let suffix = String(before[deliveredRange.upperBound...].prefix(anchorChars))

        let regionStart: String.Index
        if prefix.isEmpty {
            regionStart = after.startIndex
        } else if let r = after.range(of: prefix) {
            regionStart = r.upperBound
        } else {
            return []
        }

        let regionEnd: String.Index
        if suffix.isEmpty {
            regionEnd = after.endIndex
        } else if let r = after.range(of: suffix, range: regionStart..<after.endIndex) {
            regionEnd = r.lowerBound
        } else {
            return []
        }
        guard regionStart <= regionEnd else { return [] }

        let current = String(after[regionStart..<regionEnd])
        // Grew far beyond what we delivered: the user kept writing, they
        // didn't correct us.
        guard current.count <= needle.count * 2 + 80 else { return [] }

        return substitutions(from: words(needle), to: words(current))
    }

    /// Word-level substitutions between two token lists, via the standard LCS
    /// backtrace. Only 1-for-1 replacements count — an insertion or a deletion
    /// is the user adding or cutting something, not fixing a mis-hearing.
    static func substitutions(from old: [String], to new: [String]) -> [Change] {
        // Both sides are one dictation long, so the quadratic table is tiny.
        // The cap is belt-and-braces against a pathological field read.
        guard old.count <= 600, new.count <= 600 else { return [] }
        if old.isEmpty || new.isEmpty { return [] }

        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1),
                            count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var changes: [Change] = []
        var i = 0, j = 0
        while i < old.count && j < new.count {
            if old[i] == new[j] {
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                // `old[i]` was dropped. If exactly one new word takes its
                // place before the sequences resynchronise, that's a
                // substitution; anything else is a structural edit.
                if table[i + 1][j] == table[i][j + 1] {
                    changes.append(Change(heard: old[i], corrected: new[j]))
                    i += 1; j += 1
                } else {
                    i += 1
                }
            } else {
                j += 1
            }
            if changes.count > maxChangesPerDictation { return [] }
        }
        return changes
    }

    /// Whether a substitution looks like a correction of what was *heard*,
    /// rather than the user rewording.
    ///
    /// Three shapes qualify, and nothing else:
    /// - a pure casing/punctuation fix ("github" → "GitHub"),
    /// - a sound-alike respelling ("Goff" → "Gough"),
    /// - a near-miss of one or two characters ("Postgres" → "Postgress").
    static func looksLikeCorrection(_ change: Change) -> Bool {
        let heard = PhoneticKey.normalizedLetters(change.heard)
        let corrected = PhoneticKey.normalizedLetters(change.corrected)
        guard heard.count >= 3, corrected.count >= 2 else { return false }
        // Identical letters, different presentation — a casing or punctuation
        // fix, and one of the most useful rules a user can have.
        if heard == corrected {
            return change.heard != change.corrected
        }
        if PhoneticKey.soundsLike(candidate: change.heard, pattern: change.corrected) { return true }
        let ceiling = max(1, min(2, heard.count / 3))
        return PhoneticKey.editDistance(heard, corrected, ceiling: ceiling) <= ceiling
    }

    /// Split into comparable tokens: whitespace-separated, with surrounding
    /// punctuation stripped so "Gough." and "Gough" compare equal. Tokens that
    /// reduce to nothing (bare punctuation) are dropped.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { token in
                String(token.drop(while: { !$0.isLetter && !$0.isNumber })
                    .reversed()
                    .drop(while: { !$0.isLetter && !$0.isNumber })
                    .reversed())
            }
            .filter { !$0.isEmpty }
    }
}

extension PhoneticKey {
    /// Levenshtein distance with an early exit once every cell in a row
    /// exceeds `ceiling` — callers only ever ask "is this within N?", so
    /// there's no reason to finish computing a distance of 12.
    static func editDistance(_ a: String, _ b: String, ceiling: Int = .max) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        if abs(x.count - y.count) > ceiling { return ceiling + 1 }

        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1,
                                 current[j - 1] + 1,
                                 previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > ceiling { return ceiling + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }
}
