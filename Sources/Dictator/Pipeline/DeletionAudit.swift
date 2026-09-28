import Foundation

/// Finds content a rewrite pass dropped, one deleted stretch at a time.
///
/// The pass gates measure the whole text: ≥60% of the input's content words
/// survive, drift under a ceiling. That is right for a 50-word dictation and
/// gets steadily more lenient as the input grows — at 300 words a model can
/// lose two sentences and still clear 60%. Measured on real dictations
/// (`scratch/chunk-check`), that is exactly what whole-text passes did when
/// they went wrong: Gemma 4 12B *obeyed* a dictated instruction to delete a
/// line, and deleted it, Qwen 3.5 9B dropped a clause the speaker never retracted,
/// and both passed the gate.
///
/// So instead of a ratio this aligns input to output (word-level LCS) and
/// looks at each maximal run of input words the output doesn't keep. A deleted
/// word is *explained* when it is:
/// - a filler, hedge or function word the passes are asked to drop,
/// - a stutter (the same word either side of it),
/// - a spoken number or punctuation word (the digit/symbol checks own those),
/// - still present somewhere in the output (moved, or a passage the speaker
///   said twice), or
/// - near a spoken self-correction ("no", "sorry", "scratch that", "I mean"),
///   where dropping the abandoned version is the job.
/// What's left is content that went missing. The score is the size of the
/// worst run; a single long unexplained run is what distinguishes a dropped
/// sentence from ordinary rewording, which scatters one- and two-word
/// differences through the text.
///
/// Industry note, since it's the obvious question: none of the open-source
/// dictation tools with an LLM pass (Handy, VoiceInk, OpenWhispr, Whispering,
/// FluidVoice, Pomvox) check the output against the transcript at this level —
/// they rely on prompt wording, or at most length ratios.
enum DeletionAudit {

    /// The largest unexplained run still accepted. From `scratch/chunk-check`
    /// over 72 whole and chunked outputs on three models: acceptable outputs
    /// scored ≤ 4 (4 was heavy but faithful rewording); the losses — an obeyed
    /// instruction to delete a line, a dropped clause, a dropped second
    /// take — scored 5–24. Over 52 real Polished outputs from history it
    /// flagged one, and that one had genuinely dropped a sentence.
    static let maxUnexplainedRun = 4

    struct Finding: Sendable {
        /// Unexplained content words in the worst deleted run.
        let score: Int
        /// That run, as input words — for the log line.
        let run: String
    }

    /// True when no deleted run in `output` loses `maxUnexplainedRun + 1` or
    /// more content words from `input`.
    static func passes(input: String, output: String) -> Bool {
        worstRun(input: input, output: output).score <= maxUnexplainedRun
    }

    static func worstRun(input: String, output: String) -> Finding {
        let a = words(input)
        let b = words(output)
        guard !a.isEmpty else { return Finding(score: 0, run: "") }
        let kept = keptMask(a, b)
        let inOutput = Set(b)

        var worst = Finding(score: 0, run: "")
        var i = 0
        while i < a.count {
            if kept[i] { i += 1; continue }
            var j = i
            while j < a.count, !kept[j] { j += 1 }

            // A self-correction anywhere in or around the run licenses
            // dropping it — that is the edit the speaker asked for.
            let window = a[max(0, i - 4)..<min(a.count, j + 4)]
            if !window.contains(where: correctionCues.contains) {
                var score = 0
                for k in i..<j {
                    let w = a[k]
                    if w.count < 3 || ignorable.contains(w) || inOutput.contains(w) { continue }
                    if k > 0, a[k - 1] == w { continue }
                    if k + 1 < a.count, a[k + 1] == w { continue }
                    score += 1
                }
                if score > worst.score {
                    worst = Finding(score: score, run: a[i..<j].joined(separator: " "))
                }
            }
            i = j
        }
        return worst
    }

    // MARK: - Internals

    /// Lowercased alphanumeric words — the same currency as the pass gates.
    static func words(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// `true` at each index of `a` that belongs to a longest common
    /// subsequence with `b`. O(n·m) ints: ~0.4M for a 600-word dictation.
    private static func keptMask(_ a: [String], _ b: [String]) -> [Bool] {
        let n = a.count, m = b.count
        var kept = [Bool](repeating: false, count: n)
        guard m > 0 else { return kept }
        let width = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i * width + j] = a[i] == b[j]
                    ? dp[(i + 1) * width + j + 1] + 1
                    : max(dp[(i + 1) * width + j], dp[i * width + j + 1])
            }
        }
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                kept[i] = true; i += 1; j += 1
            } else if dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return kept
    }

    private static let correctionCues: Set<String> = [
        "no", "actually", "sorry", "wait", "scratch", "rather", "instead", "mean",
    ]

    /// Words whose disappearance never means content was lost: fillers and
    /// hedges the Polished style drops, and spoken numbers/punctuation that
    /// come back as digits and symbols (guarded by the numbers check instead).
    private static let ignorable: Set<String> = [
        // Fillers, hedges, discourse words
        "um", "umm", "uh", "uhh", "ah", "ahh", "er", "erm", "ehm", "hmm", "mhm",
        "like", "well", "basically", "literally", "actually", "just", "really",
        "you", "know", "mean", "sort", "kind", "yeah", "okay", "right", "the",
        "and", "but", "then", "that", "this", "maybe", "probably", "guess",
        // Spoken numbers
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand", "million", "billion", "point", "percent",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
        "eighth", "ninth", "tenth",
        // Spoken punctuation
        "comma", "period", "full", "stop", "question", "mark", "exclamation",
        "colon", "semicolon", "hyphen", "dash", "bracket", "brackets", "paren",
        "parens", "open", "close", "quote", "quotes", "new", "line", "paragraph",
    ]
}
