import Foundation

/// Phonetic keying for the dictionary's fuzzy match mode.
///
/// The user's dictionary only ever fired when the ASR engine already got a
/// word *nearly* right — `Vocabulary.apply`'s literal replace needs the
/// mis-hearing to be spelled exactly as the rule's pattern. That's backwards
/// for the thing dictionaries exist for: a surname Whisper renders as "Goff"
/// one time and "Gof" the next needs one rule, not a growing list of every
/// spelling the decoder has ever invented.
///
/// So a `.phonetic` entry matches on how a word *sounds*. Metaphone (Lawrence
/// Philips, 1990) collapses English spelling to its consonant skeleton:
/// "Gough" and "Goff" both key to `KF`, "Anthropik" and "Anthropic" to
/// `AN0RPK`, "Graphana" and "Grafana" to `KRFN`.
///
/// **Why there is no edit-distance gate.** The obvious second check — require
/// the raw letters to be close too — defeats the entire feature: the whole
/// point is that "Goff" and "Gough" share three letters out of five. Two
/// cheaper guards do the real work instead:
///
/// - **A common-word stoplist.** Every dangerous collision is a short, common
///   English word ("hat"/"hot", "new"/"no", "great"/"grout", "their"/"there").
///   Proper nouns and jargon — the only things anyone puts in a dictionary —
///   never appear in that list. A rule that genuinely wants "their" → "there"
///   can still be written as a literal.
/// - **A length-ratio sanity check.** Same key plus wildly different length
///   means the tokeniser handed us the wrong span, not a mis-hearing.
enum PhoneticKey {

    /// Metaphone key for a single word. Returns "" for anything with no
    /// letters in it (punctuation, digits) — callers treat an empty key as
    /// "never matches".
    static func metaphone(_ word: String) -> String {
        let letters = Array(word.uppercased().unicodeScalars.compactMap { scalar -> Character? in
            guard scalar.value >= 65, scalar.value <= 90 else { return nil }
            return Character(scalar)
        })
        guard !letters.isEmpty else { return "" }

        var out = ""
        var i = 0

        // Leading-pair exceptions: the first letter of these digraphs is
        // silent (or transformed) in English and would otherwise dominate
        // the key, since the first letter is the one position where vowels
        // are kept.
        if letters.count >= 2 {
            switch String(letters[0...1]) {
            case "AE", "GN", "KN", "PN", "WR":
                i = 1
            case "WH":
                out.append("W")
                i = 2
            default:
                if letters[0] == "X" {
                    out.append("S")
                    i = 1
                }
            }
        }

        func at(_ index: Int) -> Character? {
            (index >= 0 && index < letters.count) ? letters[index] : nil
        }
        func isVowel(_ c: Character?) -> Bool {
            guard let c else { return false }
            return "AEIOU".contains(c)
        }
        /// True when the character at `index` starts a run that matches
        /// `needle` — the "is this letter inside -CIA-?" test the rules below
        /// are written in terms of.
        func matches(_ needle: String, at index: Int) -> Bool {
            let chars = Array(needle)
            guard index >= 0, index + chars.count <= letters.count else { return false }
            for (offset, c) in chars.enumerated() where letters[index + offset] != c {
                return false
            }
            return true
        }

        var previous: Character? = nil
        while i < letters.count {
            let c = letters[i]
            let next = at(i + 1)
            // Digraphs consume their H below by setting this. Without it the
            // H is visited again on the next iteration and, sitting between a
            // consonant and a vowel, emits a spurious `H` — which is what made
            // "Graphana" (KRFHN) miss "Grafana" (KRFN).
            var consumed = 1

            // A doubled consonant contributes one sound. CC is exempt: the
            // second C in "accident" is a genuine second sound (K-S).
            if c == previous, c != "C" {
                i += 1
                continue
            }

            switch c {
            case "A", "E", "I", "O", "U":
                // Vowels survive only in the first position — everywhere else
                // they carry no information about how the word sounds to a
                // decoder that already guessed the consonants.
                if out.isEmpty && i == 0 { out.append(c) }

            case "B":
                // Silent in a final -MB ("lamb", "comb").
                if !(i == letters.count - 1 && previous == "M") { out.append("B") }

            case "C":
                if next == "H" {
                    out.append("X")                       // "church"
                    consumed = 2
                } else if matches("CIA", at: i) {
                    out.append("X")                       // "special"
                } else if next == "I" || next == "E" || next == "Y" {
                    // Silent after S: the S already produced the sound
                    // ("science", "scene").
                    if previous != "S" { out.append("S") }
                } else {
                    out.append("K")
                }

            case "D":
                if next == "G", let after = at(i + 2), "IEY".contains(after) {
                    out.append("J")                       // "edge", "dodgy"
                } else {
                    out.append("T")
                }

            case "G":
                if next == "H" {
                    consumed = 2
                    if isVowel(at(i + 2)) {
                        out.append("K")                   // "ghost", "aghast"
                    } else if i + 2 >= letters.count {
                        // Word-final -GH is the "-ough / -augh" family, which
                        // English pronounces as F often enough ("laugh",
                        // "rough", "Gough") that keying it silent would
                        // separate exactly the spellings this mode exists to
                        // unify.
                        out.append("F")
                    }
                } else if next == "N" {
                    // Silent in -GN and -GNED ("sign", "signed"); pronounced
                    // when the cluster continues ("signature").
                    let isWordEnd = (i + 2 >= letters.count) || matches("GNED", at: i)
                    if !isWordEnd { out.append("K") }
                } else if next == "I" || next == "E" || next == "Y" {
                    out.append("J")
                } else {
                    out.append("K")
                }

            case "H":
                // Voiced only between a consonant-or-start and a vowel. A H
                // that belonged to a digraph never reaches here — its
                // consonant consumed it.
                if isVowel(next) && !isVowel(previous) { out.append("H") }

            case "J":
                out.append("J")

            case "K":
                if previous != "C" { out.append("K") }

            case "F", "L", "M", "N", "R":
                out.append(c)

            case "P":
                if next == "H" {
                    out.append("F")                       // "phone", "Graphana"
                    consumed = 2
                } else {
                    out.append("P")
                }

            case "Q":
                out.append("K")

            case "S":
                if next == "H" {
                    out.append("X")
                    consumed = 2
                } else if matches("SIO", at: i) || matches("SIA", at: i) {
                    out.append("X")
                } else {
                    out.append("S")
                }

            case "T":
                if matches("TIA", at: i) || matches("TIO", at: i) {
                    out.append("X")
                } else if next == "H" {
                    out.append("0")                       // "th"
                    consumed = 2
                } else if !matches("TCH", at: i) {
                    out.append("T")
                }

            case "V":
                out.append("F")

            case "W", "Y":
                // Voiced only when it opens a syllable — a vowel after it and
                // a consonant (or the word start) before ("way", "yes").
                // Between or after vowels it's part of the vowel sound, not a
                // consonant of its own: keying the W in "clawed" separated it
                // from "Claude", which is the single most common mis-hearing
                // this app has to fix.
                if isVowel(next) && !isVowel(previous) { out.append(c) }

            case "X":
                out.append("KS")

            case "Z":
                out.append("S")

            default:
                break
            }

            previous = consumed == 2 ? "H" : c
            i += consumed
        }
        return out
    }

    /// Metaphone key for a phrase — each word keyed separately and joined, so
    /// a two-word pattern can't accidentally key the same as an unrelated
    /// single word whose letters happen to run together.
    static func metaphonePhrase(_ phrase: String) -> String {
        words(in: phrase)
            .map { metaphone($0) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Split a phrase into its words, keeping intra-word apostrophes so
    /// "O'Brien" stays one token.
    static func words(in phrase: String) -> [String] {
        phrase
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" })
            .map(String.init)
    }

    /// Letters only, lowercased — the comparison form for the length and
    /// stoplist checks, so casing and stray apostrophes don't count.
    static func normalizedLetters(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter })
    }

    /// Shortest pattern a phonetic rule will act on. Four letters is the
    /// point at which Metaphone keys start being specific enough to trust:
    /// below it, keys like `KT` cover "cat", "code", "kite" and "cadet".
    static let minPatternLetters = 4

    /// A pattern with its key and letters already computed.
    ///
    /// `Vocabulary.apply` tests one pattern against every word window in the
    /// dictation, so deriving the pattern's Metaphone key inside the
    /// comparison would recompute the same value hundreds of times per rule
    /// per dictation. Prepare once, test many.
    struct Pattern {
        let letters: String
        let key: String
        /// Words in the pattern — the width of the window to slide.
        let wordCount: Int
        /// False when the pattern is too short or too vague to match safely,
        /// in which case `matches` always says no.
        let isUsable: Bool

        init(_ pattern: String) {
            letters = PhoneticKey.normalizedLetters(pattern)
            key = PhoneticKey.metaphonePhrase(pattern)
            wordCount = PhoneticKey.words(in: pattern).count
            isUsable = letters.count >= PhoneticKey.minPatternLetters
                && key.replacingOccurrences(of: " ", with: "").count >= 2
                && wordCount > 0
        }

        /// Whether `candidate` is a plausible mis-hearing of this pattern.
        func matches(_ candidate: String) -> Bool {
            guard isUsable else { return false }
            let candidateLetters = PhoneticKey.normalizedLetters(candidate)
            guard candidateLetters.count >= PhoneticKey.minPatternLetters else { return false }
            // Exactly equal is a literal match — cheap to answer up front, and
            // it keeps an already-correct word from being reported as a
            // correction.
            if candidateLetters == letters { return true }

            // Same sound, very different size: the tokeniser handed us the
            // wrong span, not a respelling. Checked before the key, since it's
            // a length comparison against a Metaphone pass.
            let slack = max(2, letters.count / 3)
            guard abs(candidateLetters.count - letters.count) <= slack else { return false }
            guard PhoneticKey.metaphonePhrase(candidate) == key else { return false }

            // Everyday words are where same-key collisions actually bite
            // ("great"/"grout", "their"/"there"). A dictionary is for names and
            // jargon; a rule that really wants to rewrite a common word can say
            // so literally.
            return !PhoneticKey.isCommonWord(candidate)
        }
    }

    /// One-shot form of `Pattern.matches`, for the callers that test a single
    /// pair (the correction watcher, and deciding what kind of rule a accepted
    /// suggestion should become).
    static func soundsLike(candidate: String, pattern: String) -> Bool {
        Pattern(pattern).matches(candidate)
    }

    /// True when every word of `text` is an everyday English word. Multi-word
    /// spans have to be *entirely* common to be rejected, so a phrase like
    /// "the Gough" still matches on its distinctive half.
    static func isCommonWord(_ text: String) -> Bool {
        let parts = words(in: text)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { commonWords.contains(normalizedLetters($0)) }
    }

    /// Everyday English words of four letters or more — the collision-prone
    /// half of the language. Short words (under `minPatternLetters`) are
    /// already excluded by length, so they're deliberately absent here.
    ///
    /// This is a guard rail, not a lexicon: it only has to cover words common
    /// enough that a user would be upset to see one silently rewritten into
    /// somebody's surname. Missing an obscure word costs nothing — the rule
    /// still has to share a Metaphone key with it.
    static let commonWords: Set<String> = [
        "about", "above", "across", "actually", "after", "again", "against", "ahead",
        "almost", "alone", "along", "already", "also", "although", "always", "among",
        "another", "answer", "anyone", "anything", "around", "away",
        "back", "because", "become", "been", "before", "began", "begin", "behind",
        "being", "believe", "below", "best", "better", "between", "black", "blue",
        "body", "book", "both", "bring", "build", "business", "call", "came",
        "cannot", "care", "case", "cause", "certain", "change", "check", "child",
        "children", "city", "class", "clear", "close", "come", "coming",
        "common", "company", "complete", "computer", "could", "country", "couple",
        "course", "create", "current",
        "data", "date", "days", "deal", "dear", "decide", "deep", "design", "detail",
        "develop", "difference", "different", "does", "doing", "done", "door", "down",
        "draw", "drive", "during", "each", "early", "easy", "edit", "either",
        "else", "email", "end", "enough", "even", "evening", "ever", "every",
        "everyone", "everything", "exactly", "example", "expect", "experience",
        "face", "fact", "fair", "fall", "family", "feel", "feet", "field", "figure",
        "file", "fill", "final", "find", "fine", "first", "five", "follow", "food",
        "foot", "force", "form", "found", "four", "free", "friend", "from", "front",
        "full", "game", "gave", "general", "gets", "give", "given", "goes", "going",
        "gone", "good", "grand", "great", "green", "ground", "group", "grow", "guess",
        "half", "hand", "happen", "happy", "hard", "have", "head", "hear", "heard",
        "help", "here", "high", "hold", "home", "hope", "hour", "house", "however",
        "hundred", "idea", "important", "include", "indeed", "inside", "instead",
        "interest", "into", "issue", "item", "just", "keep", "kind", "knew", "know",
        "known", "large", "last", "late", "later", "lead", "learn", "least", "leave",
        "left", "less", "letter", "level", "life", "like", "line", "list", "little",
        "live", "local", "long", "look", "lose", "lost", "love", "made", "main",
        "make", "making", "many", "matter", "maybe", "mean", "meet", "member",
        "might", "mind", "minute", "miss", "model", "moment", "money", "month",
        "more", "morning", "most", "move", "much", "must", "name", "near", "need",
        "never", "next", "nice", "night", "none", "note", "nothing", "notice",
        "number", "offer", "office", "often", "once", "only", "open", "order",
        "other", "over", "page", "paper", "part", "party", "pass", "past", "people",
        "perhaps", "person", "phone", "pick", "place", "plan", "play", "please",
        "point", "possible", "power", "prepare", "present", "press", "pretty",
        "price", "probably", "problem", "process", "product", "project", "provide",
        "public", "pull", "push", "question", "quick", "quite", "rate", "rather",
        "read", "ready", "real", "really", "reason", "receive", "recent", "record",
        "remember", "report", "require", "rest", "result", "return", "right", "room",
        "rule", "said", "same", "save", "school", "second", "section", "seem",
        "seen", "sell", "send", "sense", "sent", "series", "serve", "service",
        "seven", "several", "shall", "share", "short", "should", "show", "side",
        "sign", "similar", "simple", "since", "single", "site", "size", "small",
        "some", "someone", "something", "sometimes", "soon", "sorry", "sort",
        "sound", "space", "speak", "special", "spend", "stand", "start", "state",
        "stay", "step", "still", "stop", "story", "study", "stuff", "such", "sure",
        "system", "table", "take", "talk", "team", "tell", "term", "test", "than",
        "thank", "thanks", "that", "their", "them", "then", "there", "these", "they",
        "thing", "think", "third", "this", "those", "though", "thought", "three",
        "through", "time", "today", "together", "told", "took", "total", "toward",
        "town", "trade", "true", "trust", "turn", "type", "under", "understand",
        "until", "upon", "use", "used", "user", "using", "usually", "value", "very",
        "view", "wait", "walk", "want", "watch", "water", "week", "well", "went",
        "were", "what", "when", "where", "whether", "which", "while", "white",
        "whole", "whose", "will", "wish", "with", "within", "without", "word",
        "work", "world", "would", "write", "wrong", "year", "yesterday", "your",
    ]
}
