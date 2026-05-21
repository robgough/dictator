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
    /// Apply every substitution stage. Order matters within a stage but the
    /// stages are independent. Empty input returns empty.
    static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        s = applyMultiWordPunctuation(to: s)
        s = applyArithmetic(to: s)
        s = applySingleWordPunctuation(to: s)
        s = applyEmojis(to: s)
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
        // ("em-dash"); `[ \t-]+` accepts either. Runs BEFORE the single-
        // word "dash" → em-dash substitution below.
        s = s.replacing(/\bem[ \t-]+dash\b/.ignoresCase(), with: "\u{2014}")  // —
        s = s.replacing(/\ben[ \t-]+dash\b/.ignoresCase(), with: "\u{2013}")  // –
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
            s = digitiseWordNumbersInArithmeticContext(s)
            s = applyDigitArithmetic(to: s)
            if s == prev { break }
        }
        return s
    }

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
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
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

    /// Regex fragment matching 0–999999 in word form. Built from sub-
    /// fragments so the grammar reads top-down: digits → tens → hundreds
    /// → thousands. The "and" before a trailing chunk is optional so both
    /// "one hundred three" and "one hundred AND three" match.
    private static let wordNumberFragment: String = {
        let one  = "(?:one|two|three|four|five|six|seven|eight|nine)"
        let teen = "(?:ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen)"
        let tens = "(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
        // 0–99: tens optionally + ones, or a teen, or a bare one, or zero.
        let zero99 = "(?:\(tens)(?:[ \\t-]+\(one))?|\(teen)|\(one)|zero)"
        // 100–999: "<one> hundred (and? <zero99>)?". Hundreds prefix is
        // restricted to the ones list (not tens) because "twenty hundred"
        // isn't natural English.
        let hundreds = "(?:\(one)[ \\t]+hundred(?:[ \\t]+(?:and[ \\t]+)?\(zero99))?)"
        // 1000–999999: "<HUNDREDS or 0-99> thousand (and? <HUNDREDS or 0-99>)?".
        let thousands = "(?:(?:\(hundreds)|\(zero99))[ \\t]+thousand(?:[ \\t]+(?:and[ \\t]+)?(?:\(hundreds)|\(zero99)))?)"
        return "(?:\(thousands)|\(hundreds)|\(zero99))"
    }()

    /// Words that take a number on their LEFT and on their RIGHT.
    private static let twoSidedOps = "plus|minus|equals|times|slash|pipe|divided[ \\t]+by"
    /// Words that take a number only on their LEFT (currently just percent).
    private static let leftOnlyOps = "percent"

    /// Pre-substitute word-numbers in arithmetic positions to digits, so
    /// the digit-based regexes in `applyArithmetic` pick them up.
    private static func digitiseWordNumbersInArithmeticContext(_ text: String) -> String {
        var s = text

        // word-number BEFORE an operator: "<word> <op>" → "<digit> <op>".
        // The trailing operator can be one of the two-sided set or the
        // left-only set (percent).
        let beforePattern = "\\b(\(wordNumberFragment))([ \\t]+)(\(twoSidedOps)|\(leftOnlyOps))\\b"
        if let beforeRegex = try? Regex(beforePattern).ignoresCase() {
            s = s.replacing(beforeRegex) { match in
                // Indexed access on AnyRegexOutput: [0] whole match,
                // [1] word-number, [2] whitespace, [3] operator.
                guard let wn = match.output[1].substring,
                      let space = match.output[2].substring,
                      let op = match.output[3].substring,
                      let n = parseWordNumber(String(wn))
                else { return String(match.output[0].substring ?? "") }
                return "\(n)\(space)\(op)"
            }
        }

        // word-number AFTER a two-sided operator: "<op> <word>" → "<op> <digit>".
        // Percent isn't here because it has no right-hand operand.
        let afterPattern = "\\b(\(twoSidedOps))([ \\t]+)(\(wordNumberFragment))\\b"
        if let afterRegex = try? Regex(afterPattern).ignoresCase() {
            s = s.replacing(afterRegex) { match in
                guard let op = match.output[1].substring,
                      let space = match.output[2].substring,
                      let wn = match.output[3].substring,
                      let n = parseWordNumber(String(wn))
                else { return String(match.output[0].substring ?? "") }
                return "\(op)\(space)\(n)"
            }
        }

        return s
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
        // `WORD emoji` and `emoji WORD` — match a single word adjacent to
        // "emoji". WORD can be multiple words ("smiling face emoji") but
        // matching one alphanumeric token at a time covers ~95% of how
        // people dictate emojis. Multi-word emoji names ("smiling face")
        // are handled via the alias map's pre-flattened entries.
        s = s.replacing(/\b([A-Za-z][A-Za-z0-9]*)[ \t]+emoji\b/.ignoresCase()) { match in
            let name = String(match.1).lowercased()
            return EmojiLookup.lookup(name).map { String($0) } ?? "\(match.1) emoji"
        }
        s = s.replacing(/\bemoji[ \t]+([A-Za-z][A-Za-z0-9]*)\b/.ignoresCase()) { match in
            let name = String(match.1).lowercased()
            return EmojiLookup.lookup(name).map { String($0) } ?? "emoji \(match.1)"
        }
        return s
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
    static func lookup(_ name: String) -> Character? {
        map[name]
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
        ]
        for (alias, emoji) in aliases {
            m[alias] = emoji
        }

        return m
    }
}
