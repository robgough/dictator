import Foundation

/// Conversation metrics for one meeting, computed deterministically from the
/// diarized transcript (never by the LLM — the coach report pass receives
/// these as given facts and is forbidden from inventing its own numbers).
///
/// Everything here is derived from `transcript.json`'s word timings + the
/// speaker roster's `isMe` flag, so it can be recomputed at any time and is
/// safe to trust. Pure Foundation on purpose: the coach replay harness in
/// `scratch/` symlinks this file to run the same maths outside the app.
struct CoachMetrics: Codable, Equatable, Sendable {
    /// Speech seconds, me vs. everyone else (word-timing based where
    /// available, segment spans otherwise).
    var myTalkSeconds: Double
    var theirTalkSeconds: Double
    /// myTalk / (myTalk + theirTalk). 0 when nobody spoke.
    var talkShareMe: Double
    /// Longest continuous run of my speech — gaps under the monologue-gap
    /// threshold (breaths, brief acknowledgements landing between my
    /// segments) don't break a run.
    var longestMonologueSeconds: Double
    /// Times one of my turns started while another speaker had been mid-turn
    /// for at least a second and kept going — i.e. I cut in, they didn't yield.
    var interruptionsByMe: Int
    /// My words per minute of my active speech. nil when I spoke too little
    /// for the number to mean anything.
    var paceWordsPerMinute: Double?
    /// Disfluencies per minute of my speech ("um", "uh", …). A *relative*
    /// signal: Parakeet normalises some fillers away, so compare this against
    /// your own other meetings, not against an absolute standard.
    var fillerWordsPerMinute: Double?
    var fillerWordCount: Int
    /// My turns that end in a question mark.
    var myQuestionCount: Int
    /// Longest stretch with nobody speaking (interior to the meeting).
    var longestSilenceSeconds: Double

    init(
        myTalkSeconds: Double = 0,
        theirTalkSeconds: Double = 0,
        talkShareMe: Double = 0,
        longestMonologueSeconds: Double = 0,
        interruptionsByMe: Int = 0,
        paceWordsPerMinute: Double? = nil,
        fillerWordsPerMinute: Double? = nil,
        fillerWordCount: Int = 0,
        myQuestionCount: Int = 0,
        longestSilenceSeconds: Double = 0
    ) {
        self.myTalkSeconds = myTalkSeconds
        self.theirTalkSeconds = theirTalkSeconds
        self.talkShareMe = talkShareMe
        self.longestMonologueSeconds = longestMonologueSeconds
        self.interruptionsByMe = interruptionsByMe
        self.paceWordsPerMinute = paceWordsPerMinute
        self.fillerWordsPerMinute = fillerWordsPerMinute
        self.fillerWordCount = fillerWordCount
        self.myQuestionCount = myQuestionCount
        self.longestSilenceSeconds = longestSilenceSeconds
    }
}

/// The coach's per-meeting record, stored on `MeetingMeta.coach`. PRIVATE BY
/// DESIGN: this is feedback about the *user*, not about the meeting — it is
/// never written into the markdown mirrors (`notes.md` / `transcript.md`),
/// never included in copy/export, and renders only in the in-app Coach
/// section. Later phases add checklist outcomes and the LLM report here;
/// every field beyond `metrics` decodes as optional so the schema can grow.
struct MeetingCoachResult: Codable, Equatable, Sendable {
    var metrics: CoachMetrics
    var generatedAt: Date
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    init(metrics: CoachMetrics, generatedAt: Date, schemaVersion: Int = MeetingCoachResult.currentSchemaVersion) {
        self.metrics = metrics
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.metrics = try c.decode(CoachMetrics.self, forKey: .metrics)
        self.generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case metrics, generatedAt, schemaVersion
    }
}

/// Computes `CoachMetrics` from a finished transcript. Pure functions over
/// the segment/word arrays — no actor, no state — so the same code runs in
/// the app's post-pass and in the scratch replay harness.
enum CoachMetricsBuilder {
    /// Gaps under this between two of my turns count as one monologue —
    /// a breath or a "mm-hm" landing between segments isn't a hand-over.
    static let monologueGapSeconds = 2.0
    /// They must have been mid-turn this long before my turn starts for it
    /// to count as me interrupting (vs. normal turn-taking in the gap).
    static let interruptionMinTheirSeconds = 1.0
    /// …and their turn must run at least this far past my start (they kept
    /// going — I talked over them rather than them finishing).
    static let interruptionOverlapSeconds = 0.3
    /// Below this much of my speech, pace/filler rates are noise — emit nil.
    static let minSecondsForRates = 60.0

    /// Whole-word disfluencies counted as fillers. Deliberately conservative —
    /// no "like"/"you know", which are real words far more often than fillers.
    static let fillerWords: Set<String> = ["um", "uh", "erm", "er", "hmm", "mmm"]

    static func build(
        transcript: MeetingTranscript,
        mySpeakerIDs: Set<String>,
        durationSeconds: Double
    ) -> CoachMetrics {
        let segments = transcript.segments.sorted { $0.start < $1.start }
        guard !segments.isEmpty else { return CoachMetrics() }

        let mine = segments.filter { mySpeakerIDs.contains($0.speakerId) }
        let theirs = segments.filter { !mySpeakerIDs.contains($0.speakerId) }

        let myTalk = talkSeconds(of: mine)
        let theirTalk = talkSeconds(of: theirs)
        let total = myTalk + theirTalk

        let myText = mine.map(\.text).joined(separator: " ")
        let myWords = wordCount(of: mine)
        let fillers = fillerCount(in: myText)
        let myMinutes = myTalk / 60

        return CoachMetrics(
            myTalkSeconds: myTalk,
            theirTalkSeconds: theirTalk,
            talkShareMe: total > 0 ? myTalk / total : 0,
            longestMonologueSeconds: longestRun(of: mine, mergingGapsUnder: monologueGapSeconds),
            interruptionsByMe: interruptions(mine: mine, theirs: theirs),
            paceWordsPerMinute: myTalk >= minSecondsForRates ? Double(myWords) / myMinutes : nil,
            fillerWordsPerMinute: myTalk >= minSecondsForRates ? Double(fillers) / myMinutes : nil,
            fillerWordCount: fillers,
            myQuestionCount: mine.count(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") }),
            longestSilenceSeconds: longestSilence(in: segments)
        )
    }

    /// Word-timing sum where the segment carries words; segment span otherwise.
    static func talkSeconds(of segments: [MeetingTranscriptSegment]) -> Double {
        segments.reduce(0) { acc, seg in
            if let words = seg.words, !words.isEmpty {
                return acc + words.reduce(0) { $0 + max(0, $1.end - $1.start) }
            }
            return acc + max(0, seg.end - seg.start)
        }
    }

    static func wordCount(of segments: [MeetingTranscriptSegment]) -> Int {
        segments.reduce(0) { acc, seg in
            if let words = seg.words, !words.isEmpty { return acc + words.count }
            return acc + seg.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    static func fillerCount(in text: String) -> Int {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .count(where: { fillerWords.contains(String($0)) })
    }

    /// Longest continuous run across `segments` (assumed same speaker side,
    /// sorted upstream is NOT required — sorts locally), merging gaps under
    /// `gap` into one run.
    static func longestRun(of segments: [MeetingTranscriptSegment], mergingGapsUnder gap: Double) -> Double {
        let sorted = segments.sorted { $0.start < $1.start }
        var longest = 0.0
        var runStart: Double?
        var runEnd = 0.0
        for seg in sorted {
            if let _ = runStart, seg.start - runEnd <= gap {
                runEnd = max(runEnd, seg.end)
            } else {
                if let s = runStart { longest = max(longest, runEnd - s) }
                runStart = seg.start
                runEnd = seg.end
            }
        }
        if let s = runStart { longest = max(longest, runEnd - s) }
        return longest
    }

    /// Count my turn-starts that land inside another speaker's established
    /// turn (they'd held the floor ≥ `interruptionMinTheirSeconds` and kept
    /// going ≥ `interruptionOverlapSeconds` past my start).
    static func interruptions(mine: [MeetingTranscriptSegment], theirs: [MeetingTranscriptSegment]) -> Int {
        mine.count { my in
            theirs.contains { other in
                my.start - other.start >= interruptionMinTheirSeconds
                    && other.end - my.start >= interruptionOverlapSeconds
            }
        }
    }

    /// Longest interior gap with nobody speaking.
    static func longestSilence(in segments: [MeetingTranscriptSegment]) -> Double {
        let sorted = segments.sorted { $0.start < $1.start }
        var coveredUntil = sorted.first?.end ?? 0
        var longest = 0.0
        for seg in sorted.dropFirst() {
            if seg.start > coveredUntil {
                longest = max(longest, seg.start - coveredUntil)
            }
            coveredUntil = max(coveredUntil, seg.end)
        }
        return longest
    }
}
