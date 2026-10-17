import Foundation

/// Term matching for the assistant's search tools.
///
/// The first version substring-matched the model's whole query against the
/// text, which meant it essentially never matched: asked to "search my notes
/// for the Q3 roadmap", a model sends `query: "Q3 roadmap"` — or worse, the
/// user's whole sentence — and no journal line contains that phrase verbatim.
/// Every search came back empty, which reads to the user as "this doesn't
/// work" and to the model as "there's nothing there", so it confidently says
/// so.
///
/// Matching on *terms* fixes the common case without pretending to be a search
/// engine: require every meaningful word, and if that finds nothing, fall back
/// to ranking by how many matched. No stemming — "roadmaps" won't find
/// "roadmap" — because the cheap version of that (prefix matching) produces
/// worse false positives than it fixes.
enum ChatSearch {
    /// Words too common to narrow anything down. Kept short deliberately: this
    /// is here to stop "what did I say about the budget" from requiring "what"
    /// and "about", not to be a real stoplist.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for",
        "is", "was", "be", "it", "this", "that", "with", "about",
        "my", "me", "i", "what", "did", "do", "does", "say", "said", "from",
        "any", "all", "some", "find", "search", "look", "please",
    ]

    /// Splits a query into the words worth matching on.
    static func terms(in query: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        let words = query.lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        let meaningful = words.filter { $0.count > 2 && !stopWords.contains($0) }
        // If the query was nothing but stop words ("what did I do"), fall back
        // to whatever was there rather than matching everything.
        return meaningful.isEmpty ? words.filter { !$0.isEmpty } : meaningful
    }

    /// How many of `terms` appear in `text`. 0 means no match.
    static func score(_ text: String, terms: [String]) -> Int {
        guard !terms.isEmpty else { return 0 }
        let haystack = text.lowercased()
        return terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }

    /// Ranks `items` against `query`: everything matching all terms first, and
    /// if nothing does, whatever matched most. Ties keep the input order, so a
    /// newest-first list stays newest-first.
    static func rank<T>(
        _ items: [T], query: String, limit: Int, text: (T) -> String
    ) -> [T] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }
        let scored = items
            .map { (item: $0, score: score(text($0), terms: terms)) }
            .filter { $0.score > 0 }
        guard !scored.isEmpty else { return [] }
        let best = scored.map(\.score).max() ?? 0
        let full = scored.filter { $0.score == terms.count }
        let chosen = full.isEmpty ? scored.filter { $0.score == best } : full
        return chosen.prefix(limit).map(\.item)
    }
}
