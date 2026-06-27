import Foundation

/// Deterministic pre-processor for spoken punctuation cues, line breaks, and
/// named emojis. Runs on the raw transcript before the LLM formatter pass —
/// every engine (MLX, Apple Foundation, None) is inconsistent at honouring
/// these rules from the prompt, especially the smaller models, so we just do
/// it ourselves.
///
/// Engine-agnostic by design: the substitutions happen upstream of any LLM
/// involvement, so even the "No LLM" path gets emojis and punctuation cues
/// for free.
enum SpokenCues {
    /// Per-feature gates. Each toggle stops one family of substitutions
    /// from firing. Defaults are all on; the caller composes whatever
    /// subset matches the active dictation mode.
    struct Options: Equatable, Sendable {
        var punctuation: Bool = true
        var numbers: Bool = true
        var times: Bool = true
        var currency: Bool = true
        var emojis: Bool = true

        static let all = Options()
        static let none = Options(
            punctuation: false, numbers: false, times: false,
            currency: false, emojis: false
        )

        /// True when at least one feature is enabled.
        var anyEnabled: Bool {
            punctuation || numbers || times || currency || emojis
        }
    }

    /// Apply every substitution stage. Order matters within a stage but
    /// the stages are independent — disabling one doesn't break the
    /// others. Empty input returns empty. `cleanup` always runs because
    /// it's pure whitespace/punctuation normalisation and is idempotent
    /// on already-clean text.
    static func apply(to text: String, options: Options = .all) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        if options.punctuation { s = applyMultiWordPunctuation(to: s) }
        if options.times       { s = applyTimes(to: s) }
        if options.numbers     { s = applyArithmetic(to: s) }
        if options.numbers     { s = applyMultiplier(to: s) }
        if options.currency    { s = applyCurrency(to: s) }
        if options.punctuation { s = applySingleWordPunctuation(to: s) }
        if options.emojis      { s = applyEmojis(to: s) }
        s = cleanup(s)
        return s
    }

    // MARK: - Punctuation stages
    //
    // Multi-word patterns run BEFORE single-word so "exclamation mark" is
    // consumed before "mark" could be picked up by anything else, and so
    // "new paragraph" is consumed before "paragraph" might be (it isn't
    // today, but the ordering is the right defensive default).

    private static func applyMultiWordPunctuation(to text: String) -> String {
        var s = text
        // Line/paragraph breaks. "new paragraph" is two newlines, "new line"
        // / "newline" is one. The literal newline characters land in the
        // transcript and the formatter pass leaves them alone (rule 2 in the
        // formatter prompt already accommodates them).
        s = s.replacing(/\bnew[ \t]+paragraph\b/.ignoresCase(), with: "\n\n")
        s = s.replacing(/\b(?:newline|new[ \t]+line)\b/.ignoresCase(), with: "\n")
        // Question / exclamation. Both have multi-word variants — single-word
        // "mark" or "point" is too ambiguous to substitute alone.
        s = s.replacing(/\bquestion[ \t]+mark\b/.ignoresCase(), with: "?")
        s = s.replacing(/\bexclamation[ \t]+(?:mark|point)\b/.ignoresCase(), with: "!")
        // Brackets and quotes. "open paren" / "open parenthesis" both work.
        s = s.replacing(/\bopen[ \t]+paren(?:thesis)?\b/.ignoresCase(), with: "(")
        s = s.replacing(/\bclose[ \t]+paren(?:thesis)?\b/.ignoresCase(), with: ")")
        // Typographic curly quotes — what people actually want when they
        // dictate quoted speech.
        s = s.replacing(/\bopen[ \t]+quote\b/.ignoresCase(), with: "\u{201C}")
        s = s.replacing(/\bclose[ \t]+quote\b/.ignoresCase(), with: "\u{201D}")
        // "full stop" is the British way of saying period; same outcome.
        s = s.replacing(/\bfull[ \t]+stop\b/.ignoresCase(), with: ".")
        // Typographic dash variants. Whisper may transcribe the spoken cue
        // with a space ("em dash") or a literal hyphen between the words
        // ("em-dash"); `[ \t-]+` accepts either. The `(?:em|m)` / `(?:en|n)`
        // alternation also catches Whisper hearing the cue as the letter
        // name — "M dash" / "N dash" — which would otherwise fall through
        // to the single-word "dash" substitution below and leave the lone
        // letter sitting in front of the em-dash.
        s = s.replacing(/\b(?:em|m)[ \t-]+dash\b/.ignoresCase(), with: "\u{2014}")  // —
        s = s.replacing(/\b(?:en|n)[ \t-]+dash\b/.ignoresCase(), with: "\u{2013}")  // –
        // Bracket / brace pairs. "open bracket" defaults to [ ] (square)
        // and "open brace" to { } (curly) — { } is the more common
        // alternative when people mean parens they say "paren".
        s = s.replacing(/\bopen[ \t]+(?:square[ \t]+)?bracket\b/.ignoresCase(), with: "[")
        s = s.replacing(/\bclose[ \t]+(?:square[ \t]+)?bracket\b/.ignoresCase(), with: "]")
        s = s.replacing(/\bopen[ \t]+(?:curly[ \t]+)?brace\b/.ignoresCase(), with: "{")
        s = s.replacing(/\bclose[ \t]+(?:curly[ \t]+)?brace\b/.ignoresCase(), with: "}")
        // Symbol-name cues. The "sign" / "symbol" qualifier is what makes
        // these safe — "at", "hash", "pound", "dollar" are all common
        // English words otherwise.
        s = s.replacing(/\bat[ \t]+(?:sign|symbol)\b/.ignoresCase(), with: "@")
        s = s.replacing(/\b(?:hash|pound|number)[ \t]+sign\b/.ignoresCase(), with: "#")
        s = s.replacing(/\bdollar[ \t]+sign\b/.ignoresCase(), with: "$")
        s = s.replacing(/\bforward[ \t]+slash\b/.ignoresCase(), with: "/")
        // "etcetera" / "et cetera" → the conventional "etc." abbreviation.
        // The optional trailing `\.?` absorbs a transcript-provided period
        // so we don't end up with "etc..".
        s = s.replacing(/\betcetera\b\.?/.ignoresCase(), with: "etc.")
        s = s.replacing(/\bet[ \t]+cetera\b\.?/.ignoresCase(), with: "etc.")
        return s
    }

    // MARK: - Arithmetic
    //
    // Substitute operators only when surrounded by digits ("5 plus 3" →
    // "5 + 3"), so common English usage of these words elsewhere ("plus
    // side", "minus the budget", "5 times a day") stays as written.
    // Numbers can be integers or decimals; signed forms aren't worth the
    // ambiguity (we'd misclassify "minus 3").

    private static func applyArithmetic(to text: String) -> String {
        var s = text
        // Each round runs the word-number digitisation pass and then the
        // digit-form substitution pass. Chained expressions like
        // "5 plus 6 equals 2" need more than one round: round 1 matches
        // "5 plus 6" (consuming positions for the second 6), so the
        // regex's next scan resumes past it and "equals 2" has no
        // digit-LHS yet. Round 2 sees "5 + 6 equals 2" and matches
        // "6 equals 2" → "6 = 2". Termination is guaranteed because every
        // round replaces operator *words* with glyphs (a strict reduction
        // in the set of operator words present); the loop ends as soon
        // as a round produces no change. Capped so a pathological input
        // can't spin forever.
        for _ in 0..<8 {
            let prev = s
            s = digitiseCompositeWordNumbers(s)
            s = unifyAdjacentDigitWords(s)
            s = applyDecimalPoint(s)
            s = digitiseWordNumbersInArithmeticContext(s)
            s = applyDigitArithmetic(to: s)
            s = applyUnaryArithmeticPrefix(s)
            if s == prev { break }
        }
        return s
    }

    /// Spoken decimals: "<LHS> point <RHS>" → "<LHS>.<RHS>". After "point",
    /// each digit word is read individually and concatenated:
    ///   "33 point three"           → "33.3"
    ///   "three point one four"     → "3.14"
    ///   "naught point five"        → "0.5"
    ///   "three point one oh four"  → "3.104"      ("oh" → 0 in this position)
    ///   "10 point 25"              → "10.25"      (already-digit RHS passes through)
    ///
    /// LHS accepts a digit-form number or a single-word small number — the
    /// arithmetic loop's `digitiseCompositeWordNumbers` pass converts things
    /// like "thirty-three" → "33" upstream, so by the time this runs the
    /// only word-form LHS still standing is the bare single-word kind that
    /// digitiseCompositeWordNumbers deliberately leaves alone.
    ///
    /// We deliberately don't bind without a LHS — bare "point five" is
    /// ambiguous prose ("at point five PM tomorrow") and false-positives
    /// would be worse than the loss.
    private static func applyDecimalPoint(_ text: String) -> String {
        guard let regex = decimalPointRegex else { return text }
        return text.replacing(regex) { match in
            let full = String(match.output[0].substring ?? "")
            guard let lhsCap = match.output[1].substring,
                  let rhsCap = match.output[2].substring
            else { return full }
            let lhs = String(lhsCap)
            let rhs = String(rhsCap)

            let lhsDigits: String
            if lhs.first?.isNumber == true {
                lhsDigits = lhs
            } else if let d = singleDigitWordValue(lhs.lowercased()) {
                lhsDigits = d
            } else {
                return full
            }

            if rhs.first?.isNumber == true {
                return "\(lhsDigits).\(rhs)"
            }
            let words = rhs.lowercased().split(whereSeparator: { $0.isWhitespace })
            let digits = words.compactMap { singleDigitWordValue(String($0)) }
            guard digits.count == words.count else { return full }
            return "\(lhsDigits).\(digits.joined())"
        }
    }

    nonisolated(unsafe) private static let decimalPointRegex: Regex<AnyRegexOutput>? = {
        // "oh" is included only inside the digit-by-digit RHS context, not
        // in the LHS or in the general onesMap, because "oh dear" / sentence-
        // initial "Oh, …" would otherwise turn into "0 dear" / "0, …".
        // Following "point" the disambiguation is implicit — nobody says
        // "point oh dear" meaning anything other than ".0…".
        let digitWord = "(?:zero|naught|nought|oh|one|two|three|four|five|six|seven|eight|nine)"
        let lhsToken = "(?:\\d+|\(digitWord))"
        let pattern = "\\b(\(lhsToken))[ \\t]+point[ \\t]+(\(digitWord)(?:[ \\t]+\(digitWord))*|\\d+)\\b"
        return try? Regex(pattern).ignoresCase()
    }()

    /// Mapping for single-digit number words used only by `applyDecimalPoint`.
    /// Kept separate from `onesMap` so "oh" / "naught" / "nought" don't leak
    /// into other contexts where they'd mangle ordinary prose.
    private static func singleDigitWordValue(_ word: String) -> String? {
        switch word {
        case "zero", "naught", "nought", "oh": "0"
        case "one":   "1"
        case "two":   "2"
        case "three": "3"
        case "four":  "4"
        case "five":  "5"
        case "six":   "6"
        case "seven": "7"
        case "eight": "8"
        case "nine":  "9"
        default: nil
        }
    }

    /// Concatenate runs of 2+ adjacent single-digit number words into a
    /// digit string: "four four seven seven seven" → "44777". Phone
    /// numbers, credit-card numbers, postcodes, area codes — anything
    /// people read out digit-by-digit. Single isolated words ("I have
    /// five apples") aren't touched.
    private static func unifyAdjacentDigitWords(_ text: String) -> String {
        guard let regex = digitWordRunRegex else { return text }
        return text.replacing(regex) { match in
            guard let phrase = match.output[1].substring else {
                return String(match.output[0].substring ?? "")
            }
            let words = phrase.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
            let digits = words
                .compactMap { onesMap[String($0)] }
                .map(String.init)
                .joined()
            return digits
        }
    }

    nonisolated(unsafe) private static let digitWordRunRegex: Regex<AnyRegexOutput>? = {
        let ones = "(?:zero|naught|nought|one|two|three|four|five|six|seven|eight|nine)"
        // {1,} = one or more *additional* ones words after the first, so
        // we need 2+ total. Single bare "five" doesn't match.
        let pattern = "\\b(\(ones)(?:[ \\t]+\(ones)){1,})\\b"
        return try? Regex(pattern).ignoresCase()
    }()

    /// Unary "plus N" / "minus N" at the start of a numeric token:
    /// "plus 44" → "+44", "minus 3" → "-3". Negative lookbehind keeps the
    /// binary case ("5 plus 3" → "5 + 3", which has already fired by the
    /// time we run) from being re-interpreted as "5 +3". `\d` here means
    /// the *immediately* preceding char isn't a digit — adequate because
    /// `applyDigitArithmetic` runs first inside the iteration loop, so
    /// any "<digit> plus <digit>" has already collapsed to "<digit> + <digit>".
    private static func applyUnaryArithmeticPrefix(_ text: String) -> String {
        guard let regex = unaryArithmeticRegex else { return text }
        return text.replacing(regex) { match in
            guard let op = match.output[1].substring,
                  let n = match.output[2].substring
            else { return String(match.output[0].substring ?? "") }
            let glyph = op.lowercased() == "minus" ? "-" : "+"
            return "\(glyph)\(n)"
        }
    }

    nonisolated(unsafe) private static let unaryArithmeticRegex: Regex<AnyRegexOutput>? = {
        let pattern = "(?<![0-9])\\b(plus|minus)[ \\t]+(\\d+(?:\\.\\d+)?)\\b"
        return try? Regex(pattern).ignoresCase()
    }()

    /// Convert composite word-numbers to digits anywhere they appear,
    /// regardless of surrounding context. "Composite" = anything with
    /// "hundred" or "thousand", or a tens-ones combo like "twenty-five".
    /// Single-word small numbers ("five", "twenty") deliberately stay as
    /// words because the natural prose style for small numbers is to
    /// spell them out — `I have five apples` reads better than `I have 5
    /// apples`. The threshold is: if you said more than one word for
    /// the number, you almost certainly want digits.
    private static func digitiseCompositeWordNumbers(_ text: String) -> String {
        guard let regex = compositeStandaloneRegex else { return text }
        return text.replacing(regex) { match in
            guard let wn = match.output[1].substring,
                  let n = parseWordNumber(String(wn))
            else { return String(match.output[0].substring ?? "") }
            return String(n)
        }
    }

    nonisolated(unsafe) private static let compositeStandaloneRegex: Regex<AnyRegexOutput>? = {
        let one  = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let teen = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        let zero99 = "(?:\(tens)(?:[ \\t-]+\(one))?|\(teen)|\(one)|zero|naught|nought)"
        // Hundreds prefix admits ones AND teens: "five hundred" → 500,
        // "sixteen hundred" → 1600. The teen-hundred shape is common
        // for years and round-ish prices ("the nineteen hundreds",
        // "sixteen hundred dollars"). Tens stay excluded — "twenty
        // hundred" isn't natural English.
        let hundreds = "(?:(?:\(one)|\(teen))[ \\t]+hundred(?:[ \\t]+(?:and[ \\t]+)?\(zero99))?)"
        let thousands = "(?:(?:\(hundreds)|\(zero99))[ \\t]+thousand(?:[ \\t]+(?:and[ \\t]+)?(?:\(hundreds)|\(zero99)))?)"
        // Crucially excludes the single-token cases. tensOnes requires the
        // ones suffix (so "twenty" alone doesn't match, but "twenty-five"
        // does). hundreds and thousands always contain a scale word.
        let tensOnes = "(?:\(tens)[ \\t-]+\(one))"
        let pattern = "\\b((?:\(thousands)|\(hundreds)|\(tensOnes)))\\b"
        return try? Regex(pattern).ignoresCase()
    }()

    private static func applyDigitArithmetic(to text: String) -> String {
        var s = text
        // <num> plus|minus|equals|times <num>
        let arithmetic = /\b(\d+(?:\.\d+)?)[ \t]+(plus|minus|equals|times)[ \t]+(\d+(?:\.\d+)?)\b/.ignoresCase()
        s = s.replacing(arithmetic) { match in
            let glyph: String
            switch match.2.lowercased() {
            case "plus":   glyph = "+"
            case "minus":  glyph = "-"
            case "equals": glyph = "="
            case "times":  glyph = "\u{00D7}"  // ×
            default:       glyph = String(match.2)
            }
            return "\(match.1) \(glyph) \(match.3)"
        }
        // <num> divided by <num> → /
        s = s.replacing(/\b(\d+(?:\.\d+)?)[ \t]+divided[ \t]+by[ \t]+(\d+(?:\.\d+)?)\b/.ignoresCase()) { match in
            "\(match.1) / \(match.2)"
        }
        // <num> slash <num> — fractions and dates ("5 slash 3" → "5/3")
        s = s.replacing(/\b(\d+)[ \t]+slash[ \t]+(\d+)\b/.ignoresCase()) { match in
            "\(match.1)/\(match.2)"
        }
        // <num> pipe <num> — niche but unambiguous
        s = s.replacing(/\b(\d+)[ \t]+pipe[ \t]+(\d+)\b/.ignoresCase()) { match in
            "\(match.1) | \(match.2)"
        }
        // <num> percent → number%
        s = s.replacing(/\b(\d+(?:\.\d+)?)[ \t]+percent\b/.ignoresCase()) { match in
            "\(match.1)%"
        }
        return s
    }

    // MARK: - Multiplier
    //
    // "<number> x" → "<number>x" multiplier notation: "two x" → "2x",
    // "10 x" → "10x", "one hundred x" → "100x", "2.5 x" → "2.5x". Like the
    // currency/percent passes, the trailing keyword (here a standalone "x")
    // licenses digitising even a single bare word-number — which the
    // arithmetic pass deliberately leaves as a word — because nobody
    // dictating "two x" means the literal letter.
    //
    // Runs after `applyArithmetic`, so composite word-numbers ("twenty-five")
    // and spoken decimals ("two point five") are already digits by the time
    // we look; only the bare single-word case still needs `parseWordNumber`.
    //
    // The "x" must be a standalone token: the negative lookahead rejects a
    // following word char or hyphen so "x-ray", "xbox", "example", and a
    // trailing "ex" ("my one ex") are left untouched. The rendered "x" is
    // always lowercase to match the "2x" convention regardless of how the
    // engine cased the utterance. This is also why SpokenCues re-runs after
    // the LLM passes — if a model re-splits "2x" to "2 x" or spells it back
    // to "two x", this pass repairs it on the second application.
    private static func applyMultiplier(to text: String) -> String {
        let pattern = "\\b(\(wordNumberFragment)|\\d+(?:\\.\\d+)?)[ \\t]+x(?![A-Za-z0-9-])"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            let full = String(match.output[0].substring ?? "")
            guard let numCap = match.output[1].substring else { return full }
            let num = String(numCap)
            let digits: String
            if num.first?.isNumber == true {
                digits = num
            } else if let n = parseWordNumber(num) {
                digits = String(n)
            } else {
                return full
            }
            return "\(digits)x"
        }
    }

    // MARK: - Currency
    //
    // Glue a currency symbol onto a digit number when a currency word
    // follows: "5 dollars" → "$5", "1600 dollars" → "$1600", "twenty
    // euros" → "€20", "five pounds" → "£5". Runs after the arithmetic
    // pass so composite word-numbers ("sixteen hundred") are already
    // digits by the time we look. A small pre-pass digitises single-
    // word amounts ("five" → "5") that the arithmetic pass doesn't
    // touch on its own.
    //
    // "Pound" is treated as currency even though it could be weight —
    // UK dictators say "pounds" for money far more often than for
    // weight (kg dominates), and US dictators use "dollars" for
    // money. The false-positive cost is small enough to accept.

    private static let currencyWordFragment = "(?:dollars?|pounds?|euros?|yen)"

    private static func applyCurrency(to text: String) -> String {
        var s = text
        s = digitiseWordNumbersBeforeCurrency(s)
        s = applyCurrencySymbols(s)
        return s
    }

    private static func digitiseWordNumbersBeforeCurrency(_ text: String) -> String {
        let pattern = "\\b(\(wordNumberFragment))([ \\t]+)(\(currencyWordFragment))\\b"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            guard let wn = match.output[1].substring,
                  let space = match.output[2].substring,
                  let cur = match.output[3].substring,
                  let n = parseWordNumber(String(wn))
            else { return String(match.output[0].substring ?? "") }
            return "\(n)\(space)\(cur)"
        }
    }

    private static func applyCurrencySymbols(_ text: String) -> String {
        var s = text
        s = s.replacing(/\b(\d+(?:\.\d+)?)[ \t]+dollars?\b/.ignoresCase()) { match in
            "$\(match.1)"
        }
        s = s.replacing(/\b(\d+(?:\.\d+)?)[ \t]+pounds?\b/.ignoresCase()) { match in
            "£\(match.1)"
        }
        s = s.replacing(/\b(\d+(?:\.\d+)?)[ \t]+euros?\b/.ignoresCase()) { match in
            "€\(match.1)"
        }
        s = s.replacing(/\b(\d+(?:\.\d+)?)[ \t]+yen\b/.ignoresCase()) { match in
            "¥\(match.1)"
        }
        return s
    }

    // MARK: - Word-number digitisation
    //
    // Supports 0–999999 in word form, including hundreds and thousands
    // with the natural "and" connective. Examples that parse:
    //   "five", "twenty-five", "one hundred and three",
    //   "five thousand and four", "twenty thousand and sixty two",
    //   "one hundred twenty-three thousand four hundred fifty-six".
    // The optional "and" before the final group is honoured but ignored —
    // British vs American style, both work. Anything outside this
    // vocabulary returns nil so the regex match is left untouched.

    private static let onesMap: [String: Int] = [
        // `naught` / `nought` are the British synonyms for zero. They're rare
        // outside numerical contexts ("naught to fear" is the only common
        // figurative use), and including them here means the digit-run pass
        // ("two naught one" → "201") and the currency pre-pass ("naught
        // dollars" → "$0") get them for free without further plumbing.
        // `oh` is NOT here — it's too overloaded with prose ("oh dear",
        // "Oh, hi") and only safe in the after-"point" position handled
        // by `applyDecimalPoint`.
        "zero": 0, "naught": 0, "nought": 0,
        "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tensMap: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// Parse word-form numbers up to 999999. Returns nil on anything not
    /// in the vocabulary. The token loop accumulates a "current" chunk
    /// (everything below the next scale word — "hundred" or "thousand"),
    /// multiplies / promotes when it hits a scale word, and adds to a
    /// running result when the scale word is "thousand".
    private static func parseWordNumber(_ raw: String) -> Int? {
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
        let tokens = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        var result = 0
        var current = 0
        var sawDigitToken = false

        for token in tokens {
            if token == "and" {
                continue  // "one hundred AND three" — connector, ignored
            }
            if let n = onesMap[token] {
                current += n
                sawDigitToken = true
            } else if let n = tensMap[token] {
                current += n
                sawDigitToken = true
            } else if token == "hundred" {
                // "hundred" multiplies the current chunk by 100.
                // "a hundred" (current == 0) → treat as 1 hundred so the
                // regex's mandatory DIGIT_ONE prefix isn't the only path
                // in; in practice the regex won't admit this without a
                // digit prefix so current > 0.
                current = max(current, 1) * 100
                sawDigitToken = true
            } else if token == "thousand" {
                result += max(current, 1) * 1000
                current = 0
                sawDigitToken = true
            } else {
                // Unrecognised token inside what the regex thought was a
                // word-number — abandon the parse so the caller leaves
                // the input alone.
                return nil
            }
        }
        guard sawDigitToken else { return nil }
        return result + current
    }

    /// Regex fragment matching word-form numbers from 0 up through
    /// the millions range. Built from sub-fragments so the grammar
    /// reads top-down: digits → tens → hundreds → thousands. The
    /// "and" before a trailing chunk is optional so both "one hundred
    /// three" and "one hundred AND three" match.
    private static let wordNumberFragment: String = {
        let one  = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let teen = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        // 0–99: tens optionally + ones, or a teen, or a bare one, or zero.
        let zero99 = "(?:\(tens)(?:[ \\t-]+\(one))?|\(teen)|\(one)|zero|naught|nought)"
        // 100–1999 via "<one|teen> hundred (and? <zero99>)?". Teens
        // are admitted so "sixteen hundred" and friends parse — common
        // for years and round prices. "Twenty hundred" stays out
        // because it isn't natural English.
        let hundreds = "(?:(?:\(one)|\(teen))[ \\t]+hundred(?:[ \\t]+(?:and[ \\t]+)?\(zero99))?)"
        // "<HUNDREDS or 0-99> thousand (and? <HUNDREDS or 0-99>)?".
        let thousands = "(?:(?:\(hundreds)|\(zero99))[ \\t]+thousand(?:[ \\t]+(?:and[ \\t]+)?(?:\(hundreds)|\(zero99)))?)"
        return "(?:\(thousands)|\(hundreds)|\(zero99))"
    }()

    /// Words that take a number on their LEFT and on their RIGHT.
    private static let twoSidedOps = "plus|minus|equals|times|slash|pipe|divided[ \\t]+by"
    /// Words that take a number only on their LEFT (currently just percent).
    private static let leftOnlyOps = "percent"

    /// Pre-substitute word-numbers in arithmetic positions to digits, so
    /// the digit-based regexes in `applyArithmetic` pick them up.
    ///
    /// Two-sided operators (plus/minus/times/…) only digitise their operands
    /// when a number sits on BOTH sides — a complete "<operand> <op> <operand>"
    /// expression. Digitising a lone operand next to the operator word was the
    /// source of a real bug: "four times a day" became "4 times a day" and
    /// "three to four times" became "three to 4 times", because "four" was
    /// digitised on spec for an arithmetic substitution that never completed
    /// (no second number). "times" especially is far more often the frequency
    /// word than a multiplier, so the operand must be flanked to count.
    /// Chained expressions ("five plus six equals two") still resolve across
    /// the `applyArithmetic` loop's rounds: each operator that collapses to a
    /// glyph exposes the next operator's left operand as a digit next round.
    ///
    /// `percent` is left-only (no right operand), so it keeps the single-sided
    /// rule: "five percent" → "5 percent" → "5%".
    private static func digitiseWordNumbersInArithmeticContext(_ text: String) -> String {
        var s = text

        // Numeric operand: a digit-form number or a word-form number.
        let operand = "(?:\\d+(?:\\.\\d+)?|\(wordNumberFragment))"

        // "<operand> <two-sided op> <operand>" — digitise whichever operands
        // are word-form; digit-form operands pass through unchanged. The
        // operator (and its surrounding whitespace) is preserved verbatim so
        // applyDigitArithmetic collapses it to a glyph on the same round.
        let twoSidedPattern = "\\b(\(operand))([ \\t]+(?:\(twoSidedOps))[ \\t]+)(\(operand))\\b"
        if let regex = try? Regex(twoSidedPattern).ignoresCase() {
            s = s.replacing(regex) { match in
                guard let lhs = match.output[1].substring,
                      let mid = match.output[2].substring,
                      let rhs = match.output[3].substring
                else { return String(match.output[0].substring ?? "") }
                return "\(digitiseOperand(String(lhs)))\(mid)\(digitiseOperand(String(rhs)))"
            }
        }

        // Left-only operators (percent): a word-number on the left, no right
        // operand required.
        let leftOnlyPattern = "\\b(\(wordNumberFragment))([ \\t]+)(\(leftOnlyOps))\\b"
        if let regex = try? Regex(leftOnlyPattern).ignoresCase() {
            s = s.replacing(regex) { match in
                guard let wn = match.output[1].substring,
                      let space = match.output[2].substring,
                      let op = match.output[3].substring,
                      let n = parseWordNumber(String(wn))
                else { return String(match.output[0].substring ?? "") }
                return "\(n)\(space)\(op)"
            }
        }

        return s
    }

    /// Digitise a single arithmetic operand: word-form numbers become digits,
    /// digit-form operands pass through untouched.
    private static func digitiseOperand(_ token: String) -> String {
        if token.first?.isNumber == true { return token }
        if let n = parseWordNumber(token) { return String(n) }
        return token
    }

    // MARK: - Times
    //
    // Digitise spoken clock times where the hour is followed by an AM/PM
    // suffix, "o'clock", or military "hours". Civilian shapes:
    //   "ten AM"          → "10am"
    //   "ten o'clock"     → "10 o'clock"
    //   "ten thirty PM"   → "10:30pm"
    //   "two fifteen AM"  → "2:15am"
    // Military shapes:
    //   "sixteen hundred hours"     → "1600 hours"
    //   "oh eight hundred hours"    → "0800 hours"
    //   "fourteen forty-five hours" → "1445 hours"
    // We deliberately require the marker word to fire — bare "ten thirty"
    // is left alone because it's often a quantity, not a time
    // ("ten thirty-dollar items"). AM/PM markers always render as
    // lowercase "am" / "pm" regardless of how Whisper punctuated or
    // cased the utterance — "A.M." and "p.m." both normalise to "am"
    // — and glue directly onto the digits with no space ("10am" not
    // "10 am") to match the dictation convention. "o'clock" also
    // lowercases but keeps its leading space because it's a word, not
    // an abbreviation. "Hours" (military marker) passes through
    // unchanged. The hour-minute shape always renders minutes as two
    // digits so "two fifteen" becomes "2:15", not "2:5".

    private static func applyTimes(to text: String) -> String {
        var s = text
        // Military "<hour> <minute> hours" before "<hour> hundred hours"
        // for the same reason as the civilian ordering below — and both
        // military passes before civilian to keep the marker sets
        // independent.
        s = applyMilitaryHourMinute(s)
        s = applyMilitaryHundred(s)
        // Hour + minute + marker has to run before the hour-only pattern,
        // otherwise the hour-only regex would consume "ten AM" out of
        // "ten thirty AM" before we ever saw the minute.
        s = applyHourMinuteWithMarker(s)
        s = applyHourWithMarker(s)
        return s
    }

    /// Hours 1–24 in word form. Includes the "twenty-one" … "twenty-four"
    /// composites so the regex can pull them in one match. Deliberately
    /// excludes "thirty" / "forty" etc. — those only make sense as
    /// minute values, and including them as hours would let "ten thirty
    /// AM" match starting at "thirty" instead of "ten".
    private static let hourWordFragment: String = {
        let single = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let twenties = "(?:twenty(?:[ \\t-]+(?:one|two|three|four))?)"
        return "(?:\(twenties)|\(single))"
    }()

    /// Minutes 0–59 in word form. Tens restricted to twenty–fifty so we
    /// don't admit "sixty" / "seventy" as minute values.
    private static let minuteWordFragment: String = {
        let one  = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let teen = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let tens = "(?:twenty|thirty|forty|fifty)"
        return "(?:\(tens)(?:[ \\t-]+\(one))?|\(teen)|\(one)|zero|naught|nought)"
    }()

    /// Matches every spoken form of the AM/PM marker — fully un-dotted
    /// ("am" / "PM"), partially dotted ("a.m" or "am."), or fully
    /// dotted ("a.m." / "P.M.") — plus "o'clock" (straight or curly
    /// apostrophe). The non-word lookahead after the alternation
    /// guards against accidental matches inside longer words like
    /// "ample" — `\b` alone is unreliable when the marker ends in a
    /// dot (boundary between two non-word chars never fires). The
    /// substitution callers strip any dots from the captured marker
    /// so output is consistently "AM" / "PM" regardless of how
    /// Whisper happened to punctuate it on a given utterance.
    private static let timeMarkerFragment = "(?:[ap]\\.?m\\.?|o['\u{2019}]clock)"

    /// Normalise an AM/PM marker by stripping any dots Whisper added
    /// and forcing the rendered form to lowercase. Whisper's case for
    /// the marker is essentially random across utterances, and lower
    /// case is what most prose styles want anyway — "10 am" reads
    /// better mid-sentence than "10 AM". `o'clock` (no dots) also
    /// normalises to lowercase for the same reason.
    private static func normalizeTimeMarker(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".", with: "").lowercased()
    }

    /// Spacing between the hour digits and the marker. AM/PM glue
    /// directly onto the digits (the common dictation convention —
    /// "10am" reads cleaner than "10 am"); the word-form "o'clock"
    /// keeps the space because it's a word, not an abbreviation.
    private static func spacingBeforeMarker(_ normalisedMarker: String) -> String {
        switch normalisedMarker {
        case "am", "pm": ""
        default: " "
        }
    }

    private static func applyHourWithMarker(_ text: String) -> String {
        // Space between hour and marker is matched but not captured —
        // we glue the marker straight onto the digits in the output
        // ("10am" not "10 am") because that's the dictation convention
        // most users prefer for casual times.
        let pattern = "\\b(\(hourWordFragment))[ \\t]+(\(timeMarkerFragment))(?![A-Za-z])"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            guard let hour = match.output[1].substring,
                  let marker = match.output[2].substring,
                  let n = parseWordNumber(String(hour))
            else { return String(match.output[0].substring ?? "") }
            let clean = normalizeTimeMarker(String(marker))
            return "\(n)\(spacingBeforeMarker(clean))\(clean)"
        }
    }

    private static func applyHourMinuteWithMarker(_ text: String) -> String {
        let pattern = "\\b(\(hourWordFragment))[ \\t]+(\(minuteWordFragment))[ \\t]+(\(timeMarkerFragment))(?![A-Za-z])"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            guard let hour = match.output[1].substring,
                  let minute = match.output[2].substring,
                  let marker = match.output[3].substring,
                  let h = parseWordNumber(String(hour)),
                  let m = parseWordNumber(String(minute))
            else { return String(match.output[0].substring ?? "") }
            let clean = normalizeTimeMarker(String(marker))
            return "\(h):\(String(format: "%02d", m))\(spacingBeforeMarker(clean))\(clean)"
        }
    }

    /// Military-time hour: 0 ("zero"), 10–23, or "oh N" for 01–09.
    /// Plain 1–9 without the "oh" prefix are EXCLUDED so quantity
    /// phrases like "five hundred hours of work" don't get rewritten
    /// as "0500 hours of work" — users wanting a low military hour
    /// use the "oh" prefix, which is the convention anyway. 10–12
    /// are admitted because the quantity reading is unnatural in
    /// English ("a thousand hours", not "ten hundred hours").
    private static let militaryHourFragment: String = {
        let single = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let teen = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let twenties = "(?:twenty(?:[ \\t-]+(?:one|two|three))?)"
        let ohN = "(?:oh[ \\t]+\(single))"
        return "(?:\(twenties)|\(teen)|\(ohN)|zero|naught|nought)"
    }()

    /// Like `parseWordNumber` but also accepts the "oh N" shape used
    /// in military speech ("oh eight" → 8).
    private static func parseMilitaryHour(_ raw: String) -> Int? {
        let tokens = raw.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if tokens.count == 2 && tokens[0] == "oh" {
            return parseWordNumber(tokens[1])
        }
        return parseWordNumber(raw)
    }

    private static func applyMilitaryHundred(_ text: String) -> String {
        let pattern = "\\b(\(militaryHourFragment))[ \\t]+hundred([ \\t]+)(hours)\\b"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            guard let hour = match.output[1].substring,
                  let space = match.output[2].substring,
                  let suffix = match.output[3].substring,
                  let h = parseMilitaryHour(String(hour))
            else { return String(match.output[0].substring ?? "") }
            return "\(String(format: "%02d", h))00\(space)\(suffix)"
        }
    }

    private static func applyMilitaryHourMinute(_ text: String) -> String {
        let pattern = "\\b(\(militaryHourFragment))[ \\t]+(\(minuteWordFragment))([ \\t]+)(hours)\\b"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            guard let hour = match.output[1].substring,
                  let minute = match.output[2].substring,
                  let space = match.output[3].substring,
                  let suffix = match.output[4].substring,
                  let h = parseMilitaryHour(String(hour)),
                  let m = parseWordNumber(String(minute))
            else { return String(match.output[0].substring ?? "") }
            return "\(String(format: "%02d", h))\(String(format: "%02d", m))\(space)\(suffix)"
        }
    }

    private static func applySingleWordPunctuation(to text: String) -> String {
        var s = text
        // These single-word cues are sometimes ambiguous with the literal
        // English words ("a period of confusion", "a colon problem", "the
        // 100m dash"). We substitute unconditionally because the formatter
        // prompt has always treated them as cues — keeping behaviour stable
        // for users coming from MLX. Per-user overrides go through the
        // existing Dictionary feature.
        s = s.replacing(/\bcomma\b/.ignoresCase(), with: ",")
        s = s.replacing(/\bperiod\b/.ignoresCase(), with: ".")
        s = s.replacing(/\bsemicolon\b/.ignoresCase(), with: ";")
        s = s.replacing(/\bcolon\b/.ignoresCase(), with: ":")
        s = s.replacing(/\bhyphen\b/.ignoresCase(), with: "-")
        // "dash" stays mapped to em-dash for backward compat — anyone who
        // wants a literal hyphen says "hyphen", anyone who wants an
        // en-dash says "en dash" (handled above).
        s = s.replacing(/\bdash\b/.ignoresCase(), with: "\u{2014}")  // —
        // Tech-y / typographic symbols. Each word is rare in normal English
        // speech so substituting unconditionally is safe; "ampersand" /
        // "asterisk" etc. don't show up in everyday conversation.
        s = s.replacing(/\btilde\b/.ignoresCase(),     with: "~")
        s = s.replacing(/\basterisk\b/.ignoresCase(),  with: "*")
        s = s.replacing(/\bampersand\b/.ignoresCase(), with: "&")
        s = s.replacing(/\bunderscore\b/.ignoresCase(), with: "_")
        s = s.replacing(/\bbacktick\b/.ignoresCase(),  with: "`")
        s = s.replacing(/\bcaret\b/.ignoresCase(),     with: "^")
        s = s.replacing(/\bellipsis\b/.ignoresCase(),  with: "\u{2026}")  // …
        s = s.replacing(/\bbackslash\b/.ignoresCase(), with: "\\")
        return s
    }

    // MARK: - Emoji stage

    private static func applyEmojis(to text: String) -> String {
        var s = text
        // Multi-word names ("thumbs up emoji", "broken heart emoji",
        // "rolling eyes emoji") are how people actually talk. Whisper
        // rarely collapses them into single tokens, so a one-word regex
        // would capture "up emoji" out of "thumbs up emoji" and look up
        // an unrelated arrow glyph.
        //
        // Strategy: try the longest prefix first (up to 3 words before
        // "emoji"). Each pass leaves text unchanged when the lookup
        // misses, letting shorter passes still pick up the emoji the
        // user intended. So "I want a thumbs up emoji" tries "a thumbs
        // up" (miss) → "thumbs up" (hits "thumbsup" alias via
        // EmojiLookup's join-form fallback) → 👍.
        //
        // Capped at 3 words because longer names ("rolling on the floor
        // laughing emoji") get a useful match via the shorter "rolling
        // emoji" / "laughing emoji" forms, and widening further raises
        // the chance of consuming unrelated prose preceding "emoji".
        for wordCount in [3, 2, 1] {
            s = substituteEmojiPhrase(in: s, wordCount: wordCount, isPrefix: true)
        }
        for wordCount in [3, 2, 1] {
            s = substituteEmojiPhrase(in: s, wordCount: wordCount, isPrefix: false)
        }
        return s
    }

    /// One pass of the emoji-name substitution. `wordCount` controls how
    /// many alphanumeric tokens precede (or follow, when `isPrefix:
    /// false`) the literal "emoji". Lookup tries the exact captured
    /// phrase first, then the space-stripped form so a captured
    /// "thumbs up" hits the curated `"thumbsup"` alias.
    private static func substituteEmojiPhrase(in text: String, wordCount: Int, isPrefix: Bool) -> String {
        let word = "[A-Za-z][A-Za-z0-9]*"
        let wordsPattern = (1...wordCount).map { _ in word }.joined(separator: "[ \\t]+")
        // `isPrefix: true` matches `<words> emoji`; `false` matches
        // `emoji <words>` — both shapes are supported because Whisper
        // sometimes flips the order.
        let pattern = isPrefix
            ? "\\b(\(wordsPattern))[ \\t]+emoji\\b"
            : "\\bemoji[ \\t]+(\(wordsPattern))\\b"
        guard let regex = try? Regex(pattern).ignoresCase() else { return text }
        return text.replacing(regex) { match in
            let full = String(match.output[0].substring ?? "")
            guard let captured = match.output[1].substring else { return full }
            // Normalise to single-space separation so multiple-tab /
            // multiple-space transcripts hit the same lookup key.
            let normalised = captured
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .lowercased()
            if let emoji = EmojiLookup.lookup(normalised) {
                return String(emoji)
            }
            return full
        }
    }

    /// Post-LLM tidy-up of delivered text. The LLM formatter passes
    /// consistently sprinkle "soft" punctuation (commas, semicolons, periods)
    /// around emojis because the substituted output looks list-shaped to a
    /// trained-on-prose model. Three rules, all idempotent:
    ///
    /// 1. Strip separators between two adjacent emojis.
    ///    "🔥, 🎉" → "🔥 🎉"
    /// 2. Strip soft punctuation after an emoji that's followed by more
    ///    content. "🔥 🎉, how are you" → "🔥 🎉 how are you"
    /// 3. Strip soft punctuation after a final emoji at end of string.
    ///    "...more consistently: 🔥 🎉." → "...more consistently: 🔥 🎉"
    ///
    /// `?` and `!` are preserved everywhere because they carry user intent
    /// the dictator might have spoken explicitly ("fire emoji question mark").
    static func tidyDelivery(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text

        // Rule 1: separators between adjacent emojis collapse to a single space.
        // `Emoji_Presentation` is what Swift Regex supports today (the broader
        // `Extended_Pictographic` property isn't recognised). That's fine for
        // our purposes — the emojis SpokenCues itself substitutes are all
        // emoji-presentation by construction (we only enter them into the
        // lookup map when `isEmojiPresentation` is true).
        let betweenEmojis = /(\p{Emoji_Presentation})[ \t]*[,;:][ \t]*(?=\p{Emoji_Presentation})/
        s = s.replacing(betweenEmojis) { match in
            "\(String(match.1)) "
        }

        // Rule 2: soft punctuation after an emoji followed by whitespace.
        // Lookahead preserves the whitespace itself so we don't accidentally
        // collapse a sentence boundary into a word boundary.
        let punctAfterEmojiMidSentence = /(\p{Emoji_Presentation})[,.;:]+(?=[ \t])/
        s = s.replacing(punctAfterEmojiMidSentence) { match in
            String(match.1)
        }

        // Rule 3: terminal soft punctuation after a final emoji.
        let terminalPunct = /(\p{Emoji_Presentation})[,.;:]+$/
        s = s.replacing(terminalPunct) { match in
            String(match.1)
        }

        return s
    }

    // MARK: - Cleanup

    private static func cleanup(_ text: String) -> String {
        var s = text
        // Promote sentence-terminal punctuation (`.`, `?`, `!`) that landed
        // after a line/paragraph break BACK across the break, dropping
        // any soft punctuation orphaned at the end of the previous line.
        //
        // Whisper consistently places sentence-terminal punctuation after
        // a spoken "new paragraph" cue rather than before it, because the
        // rising intonation of the question is heard as separator-then-
        // punct rather than punct-then-separator. The user said:
        //   "How you doing today? <pause> You know I think I'm doing OK."
        // Whisper transcribes:
        //   "How you doing today, new paragraph? You know I think..."
        // After "new paragraph" substitutes to \n\n we're left with the
        // comma trailing the first line and the `?` stranded at the start
        // of the second.
        //
        // The leading soft-punct capture is optional, covering the case
        // where Whisper dropped the comma entirely ("today\n\n? You").
        // The trailing-position lookahead `(?=\s|$)` keeps "0.5" /
        // ".5 percent off" intact when they sit at the top of a fresh
        // paragraph — a digit after `.` means it isn't a stranded
        // terminator, just a decimal.
        s = s.replacing(/([,;:]?)[ \t]*(\n+)[ \t]*([.?!])(?=\s|$)/) { match in
            "\(String(match.3))\(String(match.2))"
        }

        // Pull punctuation back against the preceding word. " comma" became
        // "," but the leading space is still there; collapse it so we get
        // "hi, there" not "hi , there".
        //
        // Use the closure form of `replacing`, not the String form with `$1`.
        // Swift's `String.replacing(Regex, with: String)` does NOT interpret
        // backreferences — `$1` would be inserted as literal text, turning
        // " ," into "$1" instead of ",".
        s = s.replacing(/[ \t]+([,.!?;:])/) { match in
            String(match.1)
        }
        // Strong terminators absorb adjacent soft punctuation. Whisper
        // routinely adds a trailing "." to spoken cues — "question mark"
        // arrives as "Question mark." which substitutes to "?." here. The
        // "?" already terminates the sentence; the period is noise.
        //
        // Applies in both directions:
        // - "?." / "!,"  → "?", "!"   (soft punctuation following ! or ?)
        // - ".?" / ",!"  → "?", "!"   (soft punctuation preceding ! or ?)
        //
        // ".." (ellipsis without the dedicated glyph) and "!!" / "??"
        // multi-character emphasis are explicitly preserved — they're
        // intentional speech-like punctuation, not Whisper noise.
        s = s.replacing(/([?!])[.,;:]+/) { match in
            String(match.1)
        }
        s = s.replacing(/[.,;:]+([?!])/) { match in
            String(match.1)
        }
        // Collapse runs of horizontal whitespace introduced by substitutions
        // landing next to existing spaces. No capture group → literal "" is
        // fine on the String form.
        s = s.replacing(/[ \t]{2,}/, with: " ")
        // Trim horizontal whitespace around the line breaks we introduced.
        s = s.replacing(/[ \t]+\n/, with: "\n")
        s = s.replacing(/\n[ \t]+/, with: "\n")
        return s
    }
}

/// Lazy emoji-name → emoji-character lookup. Built once on first use from the
/// Unicode standard via `Unicode.Scalar.properties.name`, then augmented with
/// aliases for the common synonyms users actually dictate (Unicode official
/// names are surprisingly literal — 🔥 is "FIRE" but ❤️ is "HEAVY BLACK HEART").
///
/// Iterating the full BMP + Supplementary Multilingual Plane (~140K scalars)
/// at first call costs ~10ms on Apple Silicon and yields ~3700 entries. The
/// resulting `[String: Character]` is held for the process lifetime.
enum EmojiLookup {
    /// Built lazily on first call via Swift's thread-safe `static let`
    /// initialisation. Iterating the relevant Unicode range and populating
    /// the dictionary takes ~10 ms on Apple Silicon and is amortised across
    /// the process lifetime.
    private static let map: [String: Character] = buildMap()

    /// Look up an emoji by lowercased name. Returns nil when no entry exists,
    /// so the caller can leave the original phrase intact.
    ///
    /// Lookup order matters when the user dictates the spaced form but a
    /// stored alias uses a different separator:
    ///   1. exact key — covers Unicode-scan keys and explicit aliases
    ///   2. space-stripped — "thumbs up" → "thumbsup" hits the curated
    ///      `("thumbsup", "👍")` alias
    ///   3. space-as-hyphen — "heart eyes" → "heart-eyes" hits the
    ///      Unicode-derived key (Unicode uses hyphens between modifier
    ///      words: "HEART-EYES", "STAR-STRUCK")
    static func lookup(_ name: String) -> Character? {
        if let direct = map[name] {
            return direct
        }
        let joined = name.replacingOccurrences(of: " ", with: "")
        if joined != name, let alt = map[joined] {
            return alt
        }
        let hyphenated = name.replacingOccurrences(of: " ", with: "-")
        if hyphenated != name, let alt = map[hyphenated] {
            return alt
        }
        return nil
    }

    private static func buildMap() -> [String: Character] {
        var m: [String: Character] = [:]

        // Iterate the Unicode code-point space where emojis live (basic
        // symbols through the supplemental symbols and pictographs block).
        // Cap at 0x1FB00 — beyond is Legacy Computing, which isn't emoji.
        for value in 0x0023...0x1FAFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            guard scalar.properties.isEmoji,
                  scalar.properties.isEmojiPresentation,
                  let name = scalar.properties.name else { continue }
            let lowercased = name.lowercased()
            let character = Character(scalar)
            // Full official name ("smiling face with smiling eyes").
            if m[lowercased] == nil {
                m[lowercased] = character
            }
            // Last significant word ("eyes", "fire", "heart" — but only when
            // it's unambiguous). Skipped when multiple emojis would lay claim
            // to the same single word; the aliases map below provides
            // hand-picked winners for the common collisions.
            if let last = lowercased.split(separator: " ").last {
                let key = String(last)
                if m[key] == nil {
                    m[key] = character
                }
            }
        }

        // Hand-curated aliases for synonyms users actually dictate. These
        // *override* anything the Unicode-name scan picked up — when a user
        // says "heart emoji" they want ❤️ not whatever the first heart-named
        // glyph happened to be.
        let aliases: [(String, Character)] = [
            // Faces / emotion
            ("smile", "😊"),
            ("smiley", "😀"),
            ("smiling", "😀"),
            ("happy", "😊"),
            ("sad", "😢"),
            ("cry", "😢"),
            ("crying", "😢"),
            ("laugh", "😂"),
            ("laughing", "😂"),
            ("joy", "😂"),
            ("lol", "😂"),
            ("wink", "😉"),
            ("kiss", "😘"),
            ("love", "😍"),
            ("cool", "😎"),
            ("angry", "😠"),
            ("mad", "😠"),
            ("shocked", "😱"),
            ("surprised", "😮"),
            ("confused", "😕"),
            ("thinking", "🤔"),
            ("sleep", "😴"),
            ("sleepy", "😴"),
            ("sick", "🤒"),
            ("scared", "😨"),
            ("worried", "😟"),
            ("nervous", "😬"),
            ("relieved", "😌"),
            ("smirk", "😏"),
            ("eyeroll", "🙄"),
            ("blush", "😊"),
            // Symbols / reactions
            ("heart", "❤️"),
            ("hearts", "❤️"),
            ("love", "❤️"),
            ("fire", "🔥"),
            ("flame", "🔥"),
            ("hot", "🔥"),
            ("sparkles", "✨"),
            ("sparkle", "✨"),
            ("magic", "✨"),
            ("shiny", "✨"),
            ("star", "⭐️"),
            ("hundred", "💯"),
            ("perfect", "💯"),
            ("check", "✅"),
            ("checkmark", "✅"),
            ("tick", "✅"),
            ("cross", "❌"),
            ("x", "❌"),
            ("no", "❌"),
            ("warning", "⚠️"),
            ("alert", "⚠️"),
            ("danger", "⚠️"),
            ("question", "❓"),
            ("exclamation", "❗"),
            ("bang", "❗"),
            ("plus", "➕"),
            ("minus", "➖"),
            ("info", "ℹ️"),
            // Celebration / weather
            ("party", "🎉"),
            ("tada", "🎉"),
            ("celebrate", "🎉"),
            ("celebration", "🎉"),
            ("balloon", "🎈"),
            ("balloons", "🎈"),
            ("gift", "🎁"),
            ("present", "🎁"),
            ("cake", "🎂"),
            ("birthday", "🎂"),
            ("rainbow", "🌈"),
            ("sun", "☀️"),
            ("sunny", "☀️"),
            ("moon", "🌙"),
            ("snow", "❄️"),
            ("snowflake", "❄️"),
            ("cloud", "☁️"),
            ("rain", "🌧️"),
            ("lightning", "⚡️"),
            ("zap", "⚡️"),
            ("bolt", "⚡️"),
            // Gestures
            ("thumbsup", "👍"),
            ("thumbs", "👍"),
            ("yes", "👍"),
            ("upvote", "👍"),
            ("thumbsdown", "👎"),
            ("downvote", "👎"),
            ("ok", "👌"),
            ("okay", "👌"),
            ("clap", "👏"),
            ("clapping", "👏"),
            ("applause", "👏"),
            ("wave", "👋"),
            ("hi", "👋"),
            ("hello", "👋"),
            ("bye", "👋"),
            ("muscle", "💪"),
            ("strong", "💪"),
            ("flex", "💪"),
            ("pray", "🙏"),
            ("praying", "🙏"),
            ("thanks", "🙏"),
            ("please", "🙏"),
            ("point", "👉"),
            ("eyes", "👀"),
            ("brain", "🧠"),
            ("ear", "👂"),
            ("nose", "👃"),
            ("mouth", "👄"),
            // Travel / objects
            ("rocket", "🚀"),
            ("plane", "✈️"),
            ("car", "🚗"),
            ("bike", "🚲"),
            ("bicycle", "🚲"),
            ("ship", "🚢"),
            ("boat", "⛵️"),
            ("train", "🚆"),
            ("bus", "🚌"),
            ("clock", "⏰"),
            ("alarm", "⏰"),
            ("watch", "⌚️"),
            ("phone", "📱"),
            ("computer", "💻"),
            ("laptop", "💻"),
            ("desktop", "🖥️"),
            ("keyboard", "⌨️"),
            ("mouse", "🖱️"),
            ("camera", "📷"),
            ("video", "📹"),
            ("tv", "📺"),
            ("book", "📖"),
            ("books", "📚"),
            ("pencil", "✏️"),
            ("pen", "🖊️"),
            ("paperclip", "📎"),
            ("scissors", "✂️"),
            ("lock", "🔒"),
            ("unlock", "🔓"),
            ("key", "🔑"),
            ("hammer", "🔨"),
            ("wrench", "🔧"),
            ("gear", "⚙️"),
            ("settings", "⚙️"),
            ("bell", "🔔"),
            ("mute", "🔕"),
            ("envelope", "✉️"),
            ("mail", "📧"),
            ("email", "📧"),
            ("inbox", "📥"),
            ("bin", "🗑️"),
            ("trash", "🗑️"),
            ("magnifying", "🔍"),
            ("search", "🔍"),
            ("light", "💡"),
            ("idea", "💡"),
            ("bulb", "💡"),
            ("battery", "🔋"),
            ("money", "💰"),
            ("cash", "💵"),
            ("dollar", "💵"),
            ("coin", "🪙"),
            ("chart", "📊"),
            ("graph", "📈"),
            ("calendar", "📅"),
            ("date", "📅"),
            ("clip", "🎬"),
            ("film", "🎥"),
            ("music", "🎵"),
            ("note", "🎵"),
            ("microphone", "🎤"),
            ("mic", "🎤"),
            ("speaker", "🔊"),
            ("volume", "🔊"),
            ("headphones", "🎧"),
            ("guitar", "🎸"),
            ("piano", "🎹"),
            // Animals
            ("dog", "🐶"),
            ("puppy", "🐶"),
            ("cat", "🐱"),
            ("kitten", "🐱"),
            ("rabbit", "🐰"),
            ("bunny", "🐰"),
            ("bear", "🐻"),
            ("panda", "🐼"),
            ("pig", "🐷"),
            ("cow", "🐮"),
            ("monkey", "🐵"),
            ("frog", "🐸"),
            ("chicken", "🐔"),
            ("penguin", "🐧"),
            ("bird", "🐦"),
            ("fish", "🐟"),
            ("whale", "🐳"),
            ("dolphin", "🐬"),
            ("shark", "🦈"),
            ("octopus", "🐙"),
            ("snake", "🐍"),
            ("turtle", "🐢"),
            ("lion", "🦁"),
            ("tiger", "🐯"),
            ("elephant", "🐘"),
            ("horse", "🐴"),
            ("unicorn", "🦄"),
            ("dragon", "🐉"),
            ("butterfly", "🦋"),
            ("bee", "🐝"),
            ("spider", "🕷️"),
            // Food
            ("apple", "🍎"),
            ("banana", "🍌"),
            ("orange", "🍊"),
            ("lemon", "🍋"),
            ("watermelon", "🍉"),
            ("strawberry", "🍓"),
            ("cherry", "🍒"),
            ("grape", "🍇"),
            ("pizza", "🍕"),
            ("burger", "🍔"),
            ("hamburger", "🍔"),
            ("fries", "🍟"),
            ("hotdog", "🌭"),
            ("taco", "🌮"),
            ("sandwich", "🥪"),
            ("bread", "🍞"),
            ("cheese", "🧀"),
            ("egg", "🥚"),
            ("bacon", "🥓"),
            ("salad", "🥗"),
            ("popcorn", "🍿"),
            ("cookie", "🍪"),
            ("donut", "🍩"),
            ("doughnut", "🍩"),
            ("icecream", "🍦"),
            ("coffee", "☕️"),
            ("tea", "🍵"),
            ("beer", "🍺"),
            ("wine", "🍷"),
            ("cocktail", "🍸"),
            ("champagne", "🍾"),
            ("cheers", "🍻"),
            // Sports / games
            ("soccer", "⚽️"),
            ("football", "🏈"),
            ("basketball", "🏀"),
            ("baseball", "⚾️"),
            ("tennis", "🎾"),
            ("volleyball", "🏐"),
            ("rugby", "🏉"),
            ("medal", "🏅"),
            ("trophy", "🏆"),
            ("dice", "🎲"),
            ("game", "🎮"),
            ("gamepad", "🎮"),
            ("controller", "🎮"),
            ("puzzle", "🧩"),
            ("chess", "♟️"),
            // Misc
            ("poop", "💩"),
            ("poo", "💩"),
            ("ghost", "👻"),
            ("alien", "👽"),
            ("robot", "🤖"),
            ("skull", "💀"),
            ("crown", "👑"),
            ("ring", "💍"),
            ("flower", "🌸"),
            ("rose", "🌹"),
            ("tulip", "🌷"),
            ("tree", "🌳"),
            ("cactus", "🌵"),
            ("leaf", "🍃"),
            ("mountain", "⛰️"),
            ("ocean", "🌊"),
            ("wave", "🌊"),
            ("world", "🌍"),
            ("globe", "🌍"),
            ("earth", "🌍"),
            ("anchor", "⚓️"),
            ("recycle", "♻️"),
            ("infinity", "♾️"),
            ("peace", "☮️"),
            ("yin", "☯️"),
            ("yang", "☯️"),
            ("religion", "🛐"),
            ("medical", "⚕️"),
            ("scale", "⚖️"),
            ("balance", "⚖️"),
            ("biohazard", "☣️"),
            ("radioactive", "☢️"),
            // Hand signals nobody types but everyone wants on voice
            ("shrug", "🤷"),
            ("facepalm", "🤦"),
            ("salute", "🫡"),
            ("pinch", "🤏"),
            ("middlefinger", "🖕"),
            ("finger", "🖕"),
            ("metal", "🤘"),
            ("rock", "🤘"),
            ("vulcan", "🖖"),
            ("crossed", "🤞"),
            ("victory", "✌️"),
            ("peace", "✌️"),
            // Multi-word dictation patterns the Unicode-name scan + prefix
            // derivation below doesn't reliably cover. Most "FACE WITH X"
            // emojis get a useful 2-word alias from the derivation step,
            // but emojis with idiosyncratic Unicode names (ROLLING ON THE
            // FLOOR LAUGHING, STAR-STRUCK, PLEADING FACE) only resolve
            // when an explicit alias is added.
            ("rolling eyes", "🙄"),
            ("laughing crying", "🤣"),
            ("crying laughing", "🤣"),
            ("rofl", "🤣"),
            ("star eyes", "🤩"),
            ("starry eyes", "🤩"),
            ("starstruck", "🤩"),
            ("pleading eyes", "🥺"),
            ("puppy eyes", "🥺"),
            ("pleading", "🥺"),
            ("begging", "🥺"),
            ("heart eyes", "😍"),
            ("upside down", "🙃"),
            ("upside-down", "🙃"),
            ("hot face", "🥵"),
            ("cold face", "🥶"),
            ("party face", "🥳"),
            ("partying", "🥳"),
            ("woozy", "🥴"),
            ("nauseated", "🤢"),
            ("face palm", "🤦"),
            ("thumbs up", "👍"),
            ("thumbs down", "👎"),
            ("broken heart", "💔"),
            ("on fire", "🔥"),
            // PIRATE FLAG is a ZWJ sequence (🏴 + ZWJ + ☠ + VS16), so the
            // single-scalar Unicode-name scan in `buildMap` never enters
            // it. Without this alias the wordCount=2 lookup for "pirate
            // flag" misses, the wordCount=1 fallback resolves "flag" to
            // 🏁 (CHEQUERED FLAG — first scalar whose last name-word is
            // "flag"), and "pirate" gets stranded in the output.
            ("pirate flag", "\u{1F3F4}\u{200D}\u{2620}\u{FE0F}"),

            // ----------------------------------------------------------
            // Flag ZWJ sequences + single-scalar flags with VS16.
            //
            // Same shape as the pirate-flag bug: any flag built from
            // multiple scalars (ZWJ sequences like 🏳️‍🌈, or even bare
            // 🏳️ which is base + VS16) is invisible to the scan. The
            // 1-word "flag" fallback then resolves to 🏁 (CHEQUERED FLAG)
            // and the colour/descriptor gets stranded.
            ("rainbow flag",     "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"),
            ("pride flag",       "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"),
            ("gay flag",         "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"),
            ("trans flag",       "\u{1F3F3}\u{FE0F}\u{200D}\u{26A7}\u{FE0F}"),
            ("transgender flag", "\u{1F3F3}\u{FE0F}\u{200D}\u{26A7}\u{FE0F}"),
            ("white flag",       "\u{1F3F3}\u{FE0F}"),
            ("surrender flag",   "\u{1F3F3}\u{FE0F}"),
            ("black flag",       "\u{1F3F4}"),
            ("chequered flag",   "\u{1F3C1}"),
            ("checkered flag",   "\u{1F3C1}"),
            ("racing flag",      "\u{1F3C1}"),
            ("finish flag",      "\u{1F3C1}"),
            ("triangular flag",  "\u{1F6A9}"),
            ("red flag",         "\u{1F6A9}"),
            ("crossed flags",    "\u{1F38C}"),

            // ----------------------------------------------------------
            // Regional-indicator flag pairs (country flags).
            //
            // Each country flag is two regional-indicator scalars and so
            // is also invisible to the single-scalar scan. Curated to
            // the countries a UK-based dictator is most likely to
            // mention; longer tail (~250 territories) is bloat and most
            // users won't dictate them.
            //
            // Multiple spoken forms per country where users genuinely
            // alternate ("uk flag" / "british flag" / "union jack" all
            // mean 🇬🇧).
            ("british flag",     "\u{1F1EC}\u{1F1E7}"),
            ("uk flag",          "\u{1F1EC}\u{1F1E7}"),
            ("union jack",       "\u{1F1EC}\u{1F1E7}"),
            ("english flag",     "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"),
            ("scottish flag",    "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"),
            ("welsh flag",       "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"),
            ("american flag",    "\u{1F1FA}\u{1F1F8}"),
            ("us flag",          "\u{1F1FA}\u{1F1F8}"),
            ("usa flag",         "\u{1F1FA}\u{1F1F8}"),
            ("canadian flag",    "\u{1F1E8}\u{1F1E6}"),
            ("canada flag",      "\u{1F1E8}\u{1F1E6}"),
            ("irish flag",       "\u{1F1EE}\u{1F1EA}"),
            ("ireland flag",     "\u{1F1EE}\u{1F1EA}"),
            ("australian flag",  "\u{1F1E6}\u{1F1FA}"),
            ("australia flag",   "\u{1F1E6}\u{1F1FA}"),
            ("aussie flag",      "\u{1F1E6}\u{1F1FA}"),
            ("french flag",      "\u{1F1EB}\u{1F1F7}"),
            ("france flag",      "\u{1F1EB}\u{1F1F7}"),
            ("german flag",      "\u{1F1E9}\u{1F1EA}"),
            ("germany flag",     "\u{1F1E9}\u{1F1EA}"),
            ("italian flag",     "\u{1F1EE}\u{1F1F9}"),
            ("italy flag",       "\u{1F1EE}\u{1F1F9}"),
            ("spanish flag",     "\u{1F1EA}\u{1F1F8}"),
            ("spain flag",       "\u{1F1EA}\u{1F1F8}"),
            ("portuguese flag",  "\u{1F1F5}\u{1F1F9}"),
            ("portugal flag",    "\u{1F1F5}\u{1F1F9}"),
            ("dutch flag",       "\u{1F1F3}\u{1F1F1}"),
            ("netherlands flag", "\u{1F1F3}\u{1F1F1}"),
            ("swiss flag",       "\u{1F1E8}\u{1F1ED}"),
            ("switzerland flag", "\u{1F1E8}\u{1F1ED}"),
            ("swedish flag",     "\u{1F1F8}\u{1F1EA}"),
            ("sweden flag",      "\u{1F1F8}\u{1F1EA}"),
            ("norwegian flag",   "\u{1F1F3}\u{1F1F4}"),
            ("norway flag",      "\u{1F1F3}\u{1F1F4}"),
            ("danish flag",      "\u{1F1E9}\u{1F1F0}"),
            ("denmark flag",     "\u{1F1E9}\u{1F1F0}"),
            ("japanese flag",    "\u{1F1EF}\u{1F1F5}"),
            ("japan flag",       "\u{1F1EF}\u{1F1F5}"),
            ("chinese flag",     "\u{1F1E8}\u{1F1F3}"),
            ("china flag",       "\u{1F1E8}\u{1F1F3}"),
            ("korean flag",      "\u{1F1F0}\u{1F1F7}"),
            ("korea flag",       "\u{1F1F0}\u{1F1F7}"),
            ("indian flag",      "\u{1F1EE}\u{1F1F3}"),
            ("india flag",       "\u{1F1EE}\u{1F1F3}"),
            ("brazilian flag",   "\u{1F1E7}\u{1F1F7}"),
            ("brazil flag",      "\u{1F1E7}\u{1F1F7}"),
            ("mexican flag",     "\u{1F1F2}\u{1F1FD}"),
            ("mexico flag",      "\u{1F1F2}\u{1F1FD}"),
            ("russian flag",     "\u{1F1F7}\u{1F1FA}"),
            ("russia flag",      "\u{1F1F7}\u{1F1FA}"),
            ("ukrainian flag",   "\u{1F1FA}\u{1F1E6}"),
            ("ukraine flag",     "\u{1F1FA}\u{1F1E6}"),
            ("eu flag",          "\u{1F1EA}\u{1F1FA}"),
            ("european flag",    "\u{1F1EA}\u{1F1FA}"),

            // ----------------------------------------------------------
            // Heart variants built from ZWJ sequences.
            //
            // The 2-word lookup misses ZWJ hearts, and the 1-word "heart"
            // fallback resolves to ❤️ via the curated alias — wrong
            // emoji, descriptor stranded.
            ("heart on fire",  "\u{2764}\u{FE0F}\u{200D}\u{1F525}"),
            ("burning heart",  "\u{2764}\u{FE0F}\u{200D}\u{1F525}"),
            ("flaming heart",  "\u{2764}\u{FE0F}\u{200D}\u{1F525}"),
            ("mending heart",  "\u{2764}\u{FE0F}\u{200D}\u{1FA79}"),
            ("healing heart",  "\u{2764}\u{FE0F}\u{200D}\u{1FA79}"),

            // ----------------------------------------------------------
            // Profession ZWJ sequences (gendered + neutral).
            //
            // Not strictly bug-shaped (the 1-word fallback misses since
            // none of "cook"/"astronaut"/"firefighter"/... are in the
            // scan map), but without explicit aliases the user gets no
            // emoji at all. Cover the common professions in all three
            // gender variants. Person variants use 🧑.
            ("man cook",          "\u{1F468}\u{200D}\u{1F373}"),
            ("woman cook",        "\u{1F469}\u{200D}\u{1F373}"),
            ("cook",              "\u{1F9D1}\u{200D}\u{1F373}"),
            ("chef",              "\u{1F9D1}\u{200D}\u{1F373}"),
            ("man astronaut",     "\u{1F468}\u{200D}\u{1F680}"),
            ("woman astronaut",   "\u{1F469}\u{200D}\u{1F680}"),
            ("astronaut",         "\u{1F9D1}\u{200D}\u{1F680}"),
            ("man firefighter",   "\u{1F468}\u{200D}\u{1F692}"),
            ("woman firefighter", "\u{1F469}\u{200D}\u{1F692}"),
            ("firefighter",       "\u{1F9D1}\u{200D}\u{1F692}"),
            ("man teacher",       "\u{1F468}\u{200D}\u{1F3EB}"),
            ("woman teacher",     "\u{1F469}\u{200D}\u{1F3EB}"),
            ("teacher",           "\u{1F9D1}\u{200D}\u{1F3EB}"),
            ("man scientist",     "\u{1F468}\u{200D}\u{1F52C}"),
            ("woman scientist",   "\u{1F469}\u{200D}\u{1F52C}"),
            ("scientist",         "\u{1F9D1}\u{200D}\u{1F52C}"),
            ("man technologist",  "\u{1F468}\u{200D}\u{1F4BB}"),
            ("woman technologist","\u{1F469}\u{200D}\u{1F4BB}"),
            ("technologist",      "\u{1F9D1}\u{200D}\u{1F4BB}"),
            ("programmer",        "\u{1F9D1}\u{200D}\u{1F4BB}"),
            ("developer",         "\u{1F9D1}\u{200D}\u{1F4BB}"),
            ("coder",             "\u{1F9D1}\u{200D}\u{1F4BB}"),
            ("man artist",        "\u{1F468}\u{200D}\u{1F3A8}"),
            ("woman artist",      "\u{1F469}\u{200D}\u{1F3A8}"),
            ("artist",            "\u{1F9D1}\u{200D}\u{1F3A8}"),
            ("man singer",        "\u{1F468}\u{200D}\u{1F3A4}"),
            ("woman singer",      "\u{1F469}\u{200D}\u{1F3A4}"),
            ("singer",            "\u{1F9D1}\u{200D}\u{1F3A4}"),
            ("man pilot",         "\u{1F468}\u{200D}\u{2708}\u{FE0F}"),
            ("woman pilot",       "\u{1F469}\u{200D}\u{2708}\u{FE0F}"),
            ("pilot",             "\u{1F9D1}\u{200D}\u{2708}\u{FE0F}"),
            ("man farmer",        "\u{1F468}\u{200D}\u{1F33E}"),
            ("woman farmer",      "\u{1F469}\u{200D}\u{1F33E}"),
            ("farmer",            "\u{1F9D1}\u{200D}\u{1F33E}"),
            ("man mechanic",      "\u{1F468}\u{200D}\u{1F527}"),
            ("woman mechanic",    "\u{1F469}\u{200D}\u{1F527}"),
            ("mechanic",          "\u{1F9D1}\u{200D}\u{1F527}"),
            ("man doctor",        "\u{1F468}\u{200D}\u{2695}\u{FE0F}"),
            ("woman doctor",      "\u{1F469}\u{200D}\u{2695}\u{FE0F}"),
            ("doctor",            "\u{1F9D1}\u{200D}\u{2695}\u{FE0F}"),
            ("nurse",             "\u{1F9D1}\u{200D}\u{2695}\u{FE0F}"),
            ("man judge",         "\u{1F468}\u{200D}\u{2696}\u{FE0F}"),
            ("woman judge",       "\u{1F469}\u{200D}\u{2696}\u{FE0F}"),
            ("judge",             "\u{1F9D1}\u{200D}\u{2696}\u{FE0F}"),
            ("man student",       "\u{1F468}\u{200D}\u{1F393}"),
            ("woman student",     "\u{1F469}\u{200D}\u{1F393}"),
            ("student",           "\u{1F9D1}\u{200D}\u{1F393}"),
            ("graduate",          "\u{1F9D1}\u{200D}\u{1F393}"),

            // ----------------------------------------------------------
            // Other ZWJ / VS16 group emojis.
            //
            // Eye-in-speech-bubble and people-holding-hands are pure
            // ZWJ; "speech bubble" alone is base + VS16 (and the base
            // isn't isEmojiPresentation, so the scan misses).
            ("eye in speech bubble", "\u{1F441}\u{FE0F}\u{200D}\u{1F5E8}\u{FE0F}"),
            ("speech bubble",        "\u{1F5E8}\u{FE0F}"),
            ("people holding hands", "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}"),
            ("holding hands",        "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}"),

            // ----------------------------------------------------------
            // Single-base scalars whose Unicode name has
            // isEmojiPresentation=false. The scan skips these entirely;
            // adding the VS16 form here makes them render as proper
            // emoji rather than monochrome text glyphs.
            ("snowman",  "\u{2603}\u{FE0F}"),
            ("eye",      "\u{1F441}\u{FE0F}"),
            ("umbrella", "\u{2602}\u{FE0F}"),

            // ----------------------------------------------------------
            // Keycap sequences (digit + VS16 + COMBINING ENCLOSING
            // KEYCAP). Three scalars each — invisible to the scan.
            ("zero key",  "0\u{FE0F}\u{20E3}"),
            ("one key",   "1\u{FE0F}\u{20E3}"),
            ("two key",   "2\u{FE0F}\u{20E3}"),
            ("three key", "3\u{FE0F}\u{20E3}"),
            ("four key",  "4\u{FE0F}\u{20E3}"),
            ("five key",  "5\u{FE0F}\u{20E3}"),
            ("six key",   "6\u{FE0F}\u{20E3}"),
            ("seven key", "7\u{FE0F}\u{20E3}"),
            ("eight key", "8\u{FE0F}\u{20E3}"),
            ("nine key",  "9\u{FE0F}\u{20E3}"),
            ("hash key",  "#\u{FE0F}\u{20E3}"),
            ("star key",  "*\u{FE0F}\u{20E3}"),
        ]
        for (alias, emoji) in aliases {
            m[alias] = emoji
        }

        // Auto-derive multi-word aliases by stripping common framing
        // words from Unicode names. "FACE WITH ROLLING EYES" yields the
        // additional key "rolling eyes" → 🙄; "WEARY FACE" yields "weary".
        // Iteration uses a sorted snapshot so the derivation is
        // deterministic — if two Unicode names strip to the same key,
        // the alphabetically-first one wins. Only fills gaps; the
        // curated aliases above keep their values.
        //
        // Crucially handles the most common dictation phrasing: people
        // say the action ("rolling eyes"), not the Unicode framing
        // ("face with rolling eyes").
        let stripPrefixes = [
            "smiling face with ",
            "face with ",
            "person ",
            "people ",
            "man ",
            "woman ",
        ]
        let stripSuffixes = [
            " face",
            " sign",
            " symbol",
        ]
        for key in m.keys.sorted() {
            guard let char = m[key], key.contains(" ") else { continue }
            for prefix in stripPrefixes where key.hasPrefix(prefix) {
                let stripped = String(key.dropFirst(prefix.count))
                if !stripped.isEmpty && m[stripped] == nil {
                    m[stripped] = char
                }
                break
            }
            for suffix in stripSuffixes where key.hasSuffix(suffix) {
                let stripped = String(key.dropLast(suffix.count))
                if !stripped.isEmpty && m[stripped] == nil {
                    m[stripped] = char
                }
                break
            }
        }

        return m
    }
}
