import Foundation

/// Cursor / selection-aware insertion of a transcribed chunk into existing
/// text. Shared by the Dictation transcript and the Scratchpad note so both
/// behave identically:
///
///   - Non-empty selection → replace the selected range (no padding — the
///     user's boundaries are intentional), keep the new text selected so it
///     can be re-dictated.
///   - Empty selection (caret) → insert at the caret with smart space padding
///     (skipped when the neighbour is already whitespace / closing
///     punctuation); caret lands after the insertion.
///   - No selection (never focused) → append at the end with a sentence-aware
///     separator (newline after a sentence terminator, otherwise a space).
///
/// Empty / whitespace-only chunks are dropped — there's nothing to add and we
/// don't want a stray space. Returns the original text + selection unchanged in
/// that case.
enum TranscriptMerge {
    static func insert(
        _ chunk: String,
        into text: String,
        at selection: NSRange?
    ) -> (text: String, selection: NSRange?) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (text, selection) }

        let ns = text as NSString
        let total = ns.length

        // Empty target → take the chunk verbatim, caret at the end.
        guard total > 0 else {
            return (trimmed, NSRange(location: (trimmed as NSString).length, length: 0))
        }

        // Cursor / selection path — guard against a stale range that doesn't
        // fit the current text (e.g. an unobserved manual edit).
        if let sel = selection,
           sel.location >= 0,
           sel.location + sel.length <= total {
            let lead: String
            let trail: String
            if sel.length == 0 {
                lead = needsLeadingSpace(in: ns, before: sel.location) ? " " : ""
                trail = needsTrailingSpace(in: ns, after: sel.location + sel.length) ? " " : ""
            } else {
                lead = ""
                trail = ""
            }
            let insertion = lead + trimmed + trail
            let newText = ns.replacingCharacters(in: sel, with: insertion)
            let leadLength = (lead as NSString).length
            let trimmedLength = (trimmed as NSString).length
            let insertedLength = (insertion as NSString).length

            if sel.length > 0 {
                return (newText, NSRange(location: sel.location + leadLength, length: trimmedLength))
            } else {
                return (newText, NSRange(location: sel.location + insertedLength, length: 0))
            }
        }

        // Fallback: append at end with a sentence-aware separator.
        let separator = endOfTextSeparator(text)
        let newText = text + separator + trimmed
        return (newText, NSRange(location: (newText as NSString).length, length: 0))
    }

    /// True when inserting before `loc` would butt up against a non-space
    /// character. Closing punctuation is *not* included — it lives on the
    /// trailing side.
    private static func needsLeadingSpace(in ns: NSString, before loc: Int) -> Bool {
        guard loc > 0, loc <= ns.length else { return false }
        let ch = ns.substring(with: NSRange(location: loc - 1, length: 1))
        guard let c = ch.first else { return false }
        return !c.isWhitespace && !c.isNewline
    }

    /// True when inserting after `loc` would butt up against a non-space
    /// character that isn't a closing punctuation glyph (avoid " ." / " ,").
    private static func needsTrailingSpace(in ns: NSString, after loc: Int) -> Bool {
        guard loc >= 0, loc < ns.length else { return false }
        let ch = ns.substring(with: NSRange(location: loc, length: 1))
        guard let c = ch.first else { return false }
        if c.isWhitespace || c.isNewline { return false }
        return !".,!?;:)]}".contains(c)
    }

    /// Separator between existing text and an appended chunk. Sentence
    /// terminators get a newline (each end-of-sentence dictation reads as a
    /// fresh thought); everything else gets a space.
    private static func endOfTextSeparator(_ text: String) -> String {
        guard let last = text.last else { return "" }
        if last.isWhitespace || last.isNewline { return "" }
        if ".!?".contains(last) { return "\n" }
        return " "
    }
}
