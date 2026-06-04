import Foundation

/// Document-wide terminology support for context-aware dictation.
///
/// The prose context the formatter sees is deliberately small (~1000 chars
/// around the caret — more would drown a small local model). But the *names
/// and terms* a document uses are valuable wherever they appear, and they
/// compress well: a term list mined from a much wider slice of the document
/// costs a handful of prompt tokens and carries none of the echo risk of
/// flowing prose. `distinctiveTerms` does that mining.
///
/// `restoreDiacritics` goes one step further for the highest-confidence
/// case: ASR routinely strips accents from names ("Siobhán" → "Siobhan").
/// When the document spells a proper noun with diacritics and the transcript
/// carries the accent-stripped form of the same word, the document is right
/// by construction — so the swap is done deterministically in the pipeline,
/// no LLM involved. Works in every mode, including Quick.
enum DocumentTerms {
    static let maxTerms = 30

    /// Mines words worth surfacing to the formatter:
    /// - words carrying diacritics ("Siobhán", "Zürich") — any case
    /// - mixed-case words ("WhisperKit", "iPhone") and letter+digit words ("GPT4")
    /// - short ALL-CAPS acronyms ("TCC", "ANE")
    /// - plain Capitalized words seen at least twice whose lowercase form
    ///   never appears (proper nouns; the frequency floor keeps one-off
    ///   sentence-starters out)
    ///
    /// Returned in priority order (diacritics first — they double as the
    /// restoration set), capped at `limit`.
    static func distinctiveTerms(in text: String, limit: Int = maxTerms) -> [String] {
        guard !text.isEmpty else { return [] }

        var diacritic: [String] = []
        var mixedOrDigit: [String] = []
        var acronyms: [String] = []
        var capitalizedOrder: [String] = []
        var capitalizedCounts: [String: Int] = [:]
        var lowercaseSeen: Set<String> = []
        var seen: Set<String> = []

        for slice in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(slice)
            guard word.count >= 2, word.count <= 30 else { continue }
            let letters = word.filter(\.isLetter)
            guard !letters.isEmpty else { continue }  // pure numbers are noise

            if word == word.lowercased() { lowercaseSeen.insert(word) }

            if word.contains(where: { $0.isLetter && !$0.isASCII }) {
                if seen.insert(word).inserted { diacritic.append(word) }
            } else if word.contains(where: \.isNumber) {
                if seen.insert(word).inserted { mixedOrDigit.append(word) }
            } else if letters.allSatisfy(\.isUppercase) {
                if letters.count <= 8, seen.insert(word).inserted { acronyms.append(word) }
            } else if word.dropFirst().contains(where: \.isUppercase) {
                // Internal capital → camelCase / PascalCase compound.
                if seen.insert(word).inserted { mixedOrDigit.append(word) }
            } else if word.first!.isUppercase, word.count >= 3 {
                if capitalizedCounts[word] == nil { capitalizedOrder.append(word) }
                capitalizedCounts[word, default: 0] += 1
            }
        }

        let properNouns = capitalizedOrder.filter { word in
            (capitalizedCounts[word] ?? 0) >= 2 && !lowercaseSeen.contains(word.lowercased())
        }
        return Array((diacritic + mixedOrDigit + acronyms + properNouns).prefix(limit))
    }

    /// Replaces accent-stripped transcript words with the document's
    /// diacritic-bearing spelling. Restricted to terms starting with an
    /// uppercase letter (proper nouns): a lowercase pair like
    /// "resume"/"résumé" is a genuine ambiguity ("resume the meeting"), but
    /// a name is a name. Matching is whole-word, case- and
    /// diacritic-insensitive; the replacement is the document form verbatim.
    static func restoreDiacritics(in text: String, terms: [String]) -> String {
        var map: [String: String] = [:]
        for term in terms {
            guard term.first?.isUppercase == true,
                  fold(term) != term.lowercased()  // actually carries diacritics
            else { continue }
            let key = fold(term)
            if map[key] == nil { map[key] = term }
        }
        guard !map.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var word = ""
        func flushWord() {
            guard !word.isEmpty else { return }
            if let documentForm = map[fold(word)], documentForm != word {
                result += documentForm
            } else {
                result += word
            }
            word = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber {
                word.append(ch)
            } else {
                flushWord()
                result.append(ch)
            }
        }
        flushWord()
        return result
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
