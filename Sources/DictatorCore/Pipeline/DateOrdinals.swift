import Foundation

/// Day-of-month ordinals, in both the form they're spoken ("the twenty-first")
/// and the form they're written ("the 21st") — and the equivalence between
/// them.
///
/// This exists for the pipeline's pass gates, not for the text itself. Deciding
/// WHICH spoken ordinals are dates is the formatter model's job: "I'm free on
/// the second" is a date and "that's the second time this month" isn't, and
/// nothing short of reading the sentence tells them apart — the month is
/// usually nowhere in the utterance, which is exactly how people speak about
/// dates in British English.
///
/// But the gates that keep a small model honest are blind to intent. To them a
/// "second" that came back as "2nd" looks like a vanished anchor word and an
/// invented number, and they revert the whole pass for it. So the gates need
/// to know that one specific rewrite is legitimate — in one direction only.
/// Words may become digits; digits may never go back to words, which is the
/// failure the number gate was built for in the first place.
///
/// Everything here works on the lowercased alphanumeric word sequences the
/// gates already use, so "twenty-first" arrives as two words and a digit
/// ordinal arrives as the single token "21st".
enum DateOrdinals {
    /// Spoken ordinals that can name a day on their own.
    private static let unitWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    /// The two tens words that can lead a compound day ("twenty-second",
    /// "thirty-first"). Forty upwards can't be a day, so they're absent.
    private static let tensWords: [String: Int] = ["twenty": 20, "thirty": 30]

    /// English ordinal suffix. Only has to be right over 1–31.
    static func suffix(_ n: Int) -> String {
        switch n {
        case 1, 21, 31: "st"
        case 2, 22: "nd"
        case 3, 23: "rd"
        default: "th"
        }
    }

    /// "21st" → 21. Nil for anything that isn't a bare day ordinal in digit
    /// form: a wrong suffix ("21th"), a year ("1995"), a plain number ("21"),
    /// or a day out of range ("32nd").
    static func day(ofDigitOrdinal token: String) -> Int? {
        let lower = token.lowercased()
        guard lower.count >= 3 else { return nil }
        let digits = lower.prefix { $0.isNumber }
        guard digits.count == lower.count - 2,
              let n = Int(digits), (1...31).contains(n),
              lower.hasSuffix(suffix(n))
        else { return nil }
        return n
    }

    static func isDigitOrdinal(_ token: String) -> Bool {
        day(ofDigitOrdinal: token) != nil
    }

    /// 21 → "21st".
    static func digitOrdinal(day n: Int) -> String { "\(n)\(suffix(n))" }

    /// The spoken form of a day, as the words a word sequence would hold:
    /// 21 → ["twenty", "first"], 2 → ["second"]. Used to credit an anchor word
    /// that the model turned into digits.
    static func spokenWords(day n: Int) -> [String] {
        if let word = unitWords.first(where: { $0.value == n })?.key {
            return [word]
        }
        let tens = (n / 10) * 10
        let unit = n % 10
        guard let tensWord = tensWords.first(where: { $0.value == tens })?.key,
              let unitWord = unitWords.first(where: { $0.value == unit })?.key
        else { return [] }
        return [tensWord, unitWord]
    }

    /// Every digit ordinal the spoken side could legitimately turn into,
    /// counted — "the second and the twenty-first" gives ["2nd": 1, "21st": 1].
    ///
    /// Counting matters: it's what stops a model inventing a second "2nd" out
    /// of one spoken "second". A compound consumes both its words so "twenty
    /// first" yields 21st and not also 1st.
    static func promotableOrdinals(in words: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        var index = 0
        while index < words.count {
            let word = words[index]
            if let tens = tensWords[word],
               index + 1 < words.count,
               let unit = unitWords[words[index + 1]], unit <= 9 {
                counts[digitOrdinal(day: tens + unit), default: 0] += 1
                index += 2
                continue
            }
            if let n = unitWords[word] {
                counts[digitOrdinal(day: n), default: 0] += 1
            }
            index += 1
        }
        return counts
    }

    /// True when the numbers in `after` are the numbers in `before`, give or
    /// take digit ordinals the spoken input licensed.
    ///
    /// - Nothing may go missing: a number in `before` that isn't in `after` is
    ///   a failure however it's spelled, so "2nd" → "second" still reverts.
    /// - Anything extra must be a day ordinal that `promotable` accounts for,
    ///   which is only ever the model writing a spoken date as digits.
    static func signaturesMatch(
        before: [String],
        after: [String],
        promotable: [String: Int]
    ) -> Bool {
        let beforeCounts = counts(before)
        let afterCounts = counts(after)
        for (token, needed) in beforeCounts where afterCounts[token, default: 0] < needed {
            return false
        }
        for (token, found) in afterCounts {
            let budget = beforeCounts[token, default: 0]
                + (isDigitOrdinal(token) ? promotable[token, default: 0] : 0)
            if found > budget { return false }
        }
        return true
    }

    /// The output's words plus the spoken form of every digit ordinal in it,
    /// so an anchor word the model correctly turned into a date still counts
    /// as having survived.
    static func anchorSet(_ words: [String]) -> Set<String> {
        var set = Set(words)
        for word in words {
            guard let n = day(ofDigitOrdinal: word) else { continue }
            set.formUnion(spokenWords(day: n))
        }
        return set
    }

    /// Rewrite every digit ordinal to its spoken words, so a drift measure
    /// compares like with like: "the 21st" and "the twenty first" come out
    /// identical instead of costing two edits.
    static func canonicalised(_ words: [String]) -> [String] {
        words.flatMap { word -> [String] in
            guard let n = day(ofDigitOrdinal: word) else { return [word] }
            let spoken = spokenWords(day: n)
            return spoken.isEmpty ? [word] : spoken
        }
    }

    private static func counts(_ tokens: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens { counts[token, default: 0] += 1 }
        return counts
    }
}
