import Foundation

/// Deterministic "smart join" applied to dictated text right before delivery,
/// driven by a fresh `InsertionContext` snapshot of the caret's surroundings.
/// Replaces the context-free heuristics (`Pipeline.relaxShortMessage` /
/// `withTrailingSpace`) whenever a snapshot is available — with real context
/// we can make the right call instead of guessing from message length.
///
/// All rules are conservative, character-level, and side-effect free:
/// - a leading space when the paste would otherwise glue onto a word
/// - a trailing space only when the following text actually needs one
///   (no more double spaces when the cursor already sits before a space)
/// - mid-sentence joins drop the transcript's automatic capital letter and,
///   when the surrounding sentence carries on after the caret, its trailing
///   full stop
enum InsertionJoiner {
    static func adjust(_ text: String, before: String, after: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        if isMidSentence(before: before) {
            result = lowercaseFirstWordIfSafe(result, before: before, after: after)
            result = stripTrailingPeriodIfSentenceContinues(result, after: after)
        }
        result = appendTrailingSpaceIfNeeded(result, after: after)
        result = prependLeadingSpaceIfNeeded(result, before: before)
        return result
    }

    // MARK: - Sentence position

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]

    /// Mid-sentence means: the caret's *current line* has preceding content
    /// whose last visible character doesn't end a sentence. Only the current
    /// line counts — a newline above the caret puts us at the start of a
    /// fresh line/paragraph regardless of how the previous one ended.
    private static func isMidSentence(before: String) -> Bool {
        let line = currentLine(of: before)
        guard let lastVisible = line.last(where: { !$0.isWhitespace }) else { return false }
        return !sentenceTerminators.contains(lastVisible)
    }

    private static func currentLine(of s: String) -> Substring {
        if let idx = s.lastIndex(where: { $0.isNewline }) {
            return s[s.index(after: idx)...]
        }
        return s[...]
    }

    // MARK: - Capitalisation

    /// Whisper capitalises the first word of every utterance; mid-sentence
    /// that's almost always wrong. Lowercase it unless there's a reason to
    /// believe the capital is real: the pronoun "I" and its contractions, an
    /// acronym, or surrounding-document evidence that the word is a proper
    /// noun (the document writes it capitalised and never lowercase).
    private static func lowercaseFirstWordIfSafe(_ text: String, before: String, after: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let firstWord = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let token = String(firstWord.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" }))
        if token == "I" || token.hasPrefix("I'") || token.hasPrefix("I’") { return text }
        let letters = token.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return text }
        let contextWords = wordSet(of: before + " " + after)
        if contextWords.contains(token), !contextWords.contains(token.lowercased()) { return text }
        return String(first).lowercased() + text.dropFirst()
    }

    /// Case-sensitive word inventory of the surrounding text, used as
    /// proper-noun evidence: "Sarah" appearing only capitalised keeps its
    /// capital; "The" loses it because the document also writes "the".
    private static func wordSet(of s: String) -> Set<String> {
        Set(
            s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
                .map(String.init)
        )
    }

    // MARK: - Trailing punctuation

    /// "I think we [should go] later." — the dictated chunk lands inside a
    /// sentence that visibly carries on (the same line resumes with a
    /// lowercase letter), so its trailing full stop would split the sentence
    /// in two. Periods only; a dictated "?" or "!" is deliberate.
    private static func stripTrailingPeriodIfSentenceContinues(_ text: String, after: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        let restOfLine = after.prefix(while: { !$0.isNewline })
        guard let next = restOfLine.first(where: { !$0.isWhitespace }), next.isLowercase else { return text }
        return String(text.dropLast())
    }

    // MARK: - Spacing

    private static let openingDelimiters: Set<Character> = ["(", "[", "{", "“", "‘"]

    /// Characters the dictation should glue straight onto: the tail of an
    /// email address or URL, a compound word's hyphen, a currency amount.
    private static let attachingJoiners: Set<Character> = [
        "@", "/", "\\", "-", "_", "–", "—", "~", "#", "$", "£", "€", "¥",
    ]

    /// A trailing space when the following text needs one to not glue on —
    /// and, matching the long-standing delivery behaviour, when the caret is
    /// at the very end of the field (so the next keystroke or dictation
    /// doesn't mash into this chunk).
    private static func appendTrailingSpaceIfNeeded(_ text: String, after: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return text }
        guard let next = after.first else { return text + " " }
        if next.isWhitespace { return text }
        if next.isLetter || next.isNumber || openingDelimiters.contains(next) { return text + " " }
        return text // attaching punctuation follows (".", ",", ")", "”", …)
    }

    /// A leading space when the paste would otherwise glue onto the word
    /// before the caret. Straight quotes are ambiguous (opening vs closing);
    /// preceded-by-whitespace means opening, so no space.
    private static func prependLeadingSpaceIfNeeded(_ text: String, before: String) -> String {
        guard let first = text.first, first.isLetter || first.isNumber else { return text }
        guard let prev = before.last else { return text }
        if prev.isWhitespace || openingDelimiters.contains(prev) || attachingJoiners.contains(prev) { return text }
        if prev == "\"" || prev == "'" {
            let beforeQuote = before.dropLast().last
            if beforeQuote == nil || beforeQuote!.isWhitespace { return text }
        }
        return " " + text
    }
}
