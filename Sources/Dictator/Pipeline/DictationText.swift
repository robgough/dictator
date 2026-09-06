import Foundation
import NaturalLanguage

/// Pure text utilities the dictation pipeline leans on for anything that has to
/// reason about *shape* rather than meaning: how long a dictation is, where its
/// sentences end, how to break it into model-sized chunks, and the
/// numbered-sentence protocol behind automatic paragraphing.
///
/// Deliberately free of app state, settings and actor isolation — every member
/// is `nonisolated static`, so the pipeline can call these from the main actor
/// today and a background task tomorrow without re-plumbing. That also makes
/// them checkable in isolation: `scratch/dictation-text-check/` compiles this
/// exact file against a small driver and asserts the invariants below.
///
/// The load-bearing invariant, relied on by the auto-paragraph pass:
/// `applyParagraphStarts(sentences(t), _)` differs from `t` in WHITESPACE ONLY.
/// The model that drives it never emits prose — only sentence numbers — so no
/// generated text can reach the user's document through this path.
enum DictationText {

    // MARK: - Counting

    /// Whitespace-separated token count. Deliberately cruder than
    /// `Pipeline.wordSequence` (which strips punctuation for the content
    /// gates): this one only ever decides "is this long enough to chunk /
    /// paragraph", where a fast, obvious count is the right tool.
    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The text's non-whitespace characters, in order. Two strings with the
    /// same signature differ only in whitespace — which is exactly the
    /// guarantee the paragraph pass has to prove before it replaces the user's
    /// text with a re-joined one.
    nonisolated static func nonWhitespaceSignature(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    // MARK: - Sentences

    /// Sentence-tokenises with `NLTokenizer`, trimming each sentence and
    /// dropping empties. Handles abbreviations and decimals far better than a
    /// "split on ." heuristic, which is why the paragraph and chunking passes
    /// both go through it rather than rolling their own.
    nonisolated static func sentences(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { out.append(sentence) }
            return true
        }
        return out
    }

    // MARK: - Chunking

    /// Splits `text` into sentence-bounded chunks of roughly `targetWords`.
    ///
    /// Greedy fill: sentences accumulate until the next one would push the
    /// chunk past the target, at which point the chunk closes. A single
    /// sentence longer than the target becomes its own (oversize) chunk rather
    /// than being cut mid-sentence — the passes that consume these run a
    /// content-preservation gate per chunk, and a half-sentence would fail it
    /// for the wrong reason.
    ///
    /// Guarantees: chunk boundaries are always sentence boundaries; joining the
    /// chunks with a single space reproduces `sentences(text).joined(separator: " ")`.
    nonisolated static func chunks(_ text: String, targetWords: Int) -> [String] {
        let target = max(1, targetWords)
        let all = sentences(text)
        guard !all.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        var out: [String] = []
        var current: [String] = []
        var currentWords = 0

        for sentence in all {
            let words = wordCount(sentence)
            if !current.isEmpty && currentWords + words > target {
                out.append(current.joined(separator: " "))
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += words
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    // MARK: - Paragraph protocol

    /// Parses the paragraphing model's reply — a comma-separated list of
    /// sentence numbers, or "none". Every non-numeric shape (a refusal, a
    /// sentence of prose, an empty string) lands on the same answer: no split.
    ///
    /// Returns sorted, de-duplicated numbers in `2...sentenceCount`. 1 is never
    /// a valid paragraph start (the first sentence always starts one), and an
    /// out-of-range number means the model lost count — dropping it is strictly
    /// safer than trusting the rest of its answer, but the remaining in-range
    /// numbers are still usable because applying them can only move whitespace.
    nonisolated static func parseParagraphStarts(_ reply: String, sentenceCount: Int) -> [Int] {
        guard sentenceCount > 1 else { return [] }
        var found: [Int] = []
        var seen = Set<Int>()
        var digits = ""

        func flush() {
            defer { digits = "" }
            // Long digit runs are junk, not sentence numbers; `Int()` also
            // returns nil on overflow, so both paths drop out here.
            guard !digits.isEmpty, digits.count <= 6, let value = Int(digits) else { return }
            guard value > 1, value <= sentenceCount else { return }
            if seen.insert(value).inserted { found.append(value) }
        }

        for character in reply {
            if character.isASCII && character.isNumber {
                digits.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found.sorted()
    }

    /// Re-joins `sentences` into paragraphs, starting a new one at each number
    /// in `starts`. Sentences within a paragraph are joined with a single
    /// space; paragraphs with a blank line.
    ///
    /// Whitespace-only by construction: no character outside `sentences` is
    /// ever emitted, and every sentence is emitted exactly once, in order.
    nonisolated static func applyParagraphStarts(_ sentences: [String], _ starts: [Int]) -> String {
        guard !sentences.isEmpty else { return "" }
        let startSet = Set(starts)
        var paragraphs: [String] = []
        var current: [String] = []

        for (index, sentence) in sentences.enumerated() {
            let number = index + 1
            if number > 1, startSet.contains(number), !current.isEmpty {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
            current.append(sentence)
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n\n")
    }
}
