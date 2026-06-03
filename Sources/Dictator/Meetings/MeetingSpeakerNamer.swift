import Foundation

/// Speaker-name inference. After diarization the non-"Me" speakers are generic
/// ("Speaker 1", "Speaker 2"); this recovers their real names from what's
/// actually said — self-introductions ("I'm Rory", "Pat here") and direct
/// address ("thanks, Rory", "over to you, Sam").
///
/// Split of labour, learned the hard way: the LLM is asked ONLY to list the
/// first names of the participants — a task it's reliably good at. It is NOT
/// asked which speaker is which, because small local models almost always
/// attach a spoken name to the speaker who *said* it, which is backwards for
/// direct address ("thanks, Amy" is said TO Amy, not BY her). Re-prompting
/// around that failed repeatedly. So the label→name DIRECTION is resolved
/// deterministically in `assignNamesToSpeakers`: a name spoken by a speaker
/// names a DIFFERENT speaker (the one addressed/referred to) unless it's a
/// self-introduction; in the common two-party call that's simply the other
/// speaker. Votes are tallied across every occurrence.
///
/// Guards (unchanged): the name must ACTUALLY be spoken in the transcript;
/// filler / pronoun / role words are rejected; two speakers never share a name;
/// and only speakers whose label is still the diarizer default ("Speaker N" /
/// "Other") or a previous inference are touched — a hand-typed name is never
/// overwritten.
///
/// On any failure (no LLM, parse error, nothing confidently named) it returns
/// the speakers unchanged.
@MainActor
enum MeetingSpeakerNamer {
    /// Run the inference and return the speaker list with `displayName` /
    /// `nameInferred` updated for any speaker that was confidently named.
    static func inferNames(
        transcript: MeetingTranscript,
        speakers: [MeetingMeta.Speaker],
        settings: DictatorSettings
    ) async -> [MeetingMeta.Speaker] {
        guard let engine = settings.activeLLMEngine() else { return speakers }

        // Eligible = non-me speakers whose name is still inference-owned. If
        // nothing is eligible (e.g. the user already named everyone), skip.
        let hasEligible = speakers.contains { !$0.isMe && (isDefaultName($0.displayName) || $0.nameInferred) }
        guard hasEligible else { return speakers }

        let segments = transcript.segments
        guard !segments.isEmpty else { return speakers }

        // Names surface most densely in the opening (introductions) but also
        // throughout (being addressed). Cap the input so a long meeting doesn't
        // blow the token budget — the lead carries the great majority.
        let rendered = String(
            MeetingSummaryService.renderSegments(segments, speakers: speakers).prefix(16_000)
        )

        // The LLM's ONLY job is to list the participants' first names — NOT to
        // decide which speaker is which (see the type doc: it gets direction
        // backwards). Direction is resolved deterministically below.
        let raw: String
        do {
            try await engine.ensureReady()
            let result = try await engine.assist(
                selection: rendered,
                instruction: "List the first names of the people TAKING PART in this conversation (the people who speak). Include a name only if it is actually spoken in the transcript. Exclude anyone only talked about but not speaking, and exclude character names, place names, and brands. Output ONLY a JSON array of first names, e.g. [\"Sam\", \"Priya\"]. Output [] if no participant names are clear.",
                systemPrompt: nameExtractionPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
            raw = result.text
        } catch {
            NSLog("[Dictator] Speaker-name inference failed: \(error)")
            return speakers
        }

        // Candidate names: sanitised, actually-spoken, de-duplicated.
        let spokenTokens = spokenWordSet(segments)
        var candidateNames: [String] = []
        var seenLower = Set<String>()
        for rawName in parseCandidateNames(raw) {
            guard let name = sanitiseName(rawName) else { continue }
            let lower = name.lowercased()
            let primary = lower.split(separator: " ").first.map(String.init) ?? lower
            guard spokenTokens.contains(primary) else { continue }
            guard !seenLower.contains(lower) else { continue }
            seenLower.insert(lower)
            candidateNames.append(name)
        }
        guard !candidateNames.isEmpty else { return speakers }

        // Deterministic direction: assign each name to the speaker being
        // addressed/introduced, not the one talking.
        let assignment = assignNamesToSpeakers(
            candidateNames: candidateNames,
            segments: segments,
            speakers: speakers
        )
        guard !assignment.isEmpty else { return speakers }

        var result = speakers
        // Names already in play (manual or carried over) so we never collide.
        var takenNames = Set(speakers.map { $0.displayName.lowercased() })
        for (speakerID, name) in assignment {
            guard let idx = result.firstIndex(where: { $0.id == speakerID }) else { continue }
            // Only ever touch an eligible (default/inferred, non-me) speaker.
            guard !result[idx].isMe,
                  isDefaultName(result[idx].displayName) || result[idx].nameInferred else { continue }
            let lower = name.lowercased()
            guard !takenNames.contains(lower) else { continue }
            guard result[idx].displayName.caseInsensitiveCompare(name) != .orderedSame else { continue }
            takenNames.remove(result[idx].displayName.lowercased())
            takenNames.insert(lower)
            result[idx].displayName = name
            result[idx].nameInferred = true
        }
        return result
    }

    // MARK: - Deterministic direction

    /// Map each candidate name to the speaker it most likely belongs to, using
    /// address direction rather than who's talking. For every occurrence of a
    /// name we cast a vote: a self-introduction ("I'm Sam") votes for the
    /// speaker who said it (weight 3 — the strongest signal); any other mention
    /// is direct address or reference and votes for the speaker being addressed
    /// (weight 1) — in a two-party call that's simply the other speaker, else
    /// the nearest adjacent different speaker. Each name then goes to its
    /// best-supported eligible speaker, and a name/speaker pairs at most once.
    /// Returns `[speakerID: name]`.
    static func assignNamesToSpeakers(
        candidateNames: [String],
        segments: [MeetingTranscriptSegment],
        speakers: [MeetingMeta.Speaker]
    ) -> [String: String] {
        let meIDs = Set(speakers.filter { $0.isMe }.map { $0.id })
        let eligibleIDs = Set(
            speakers.filter { !$0.isMe && (isDefaultName($0.displayName) || $0.nameInferred) }.map { $0.id }
        )
        guard !eligibleIDs.isEmpty else { return [:] }
        // Non-"me" speakers that actually take a turn, in first-appearance
        // order — drives the clean two-party "the other speaker" resolution.
        let nonMeTurnIDs = orderedUnique(segments.map { $0.speakerId }.filter { !meIDs.contains($0) })

        let tokenized = segments.map { tokenize($0.text) }

        // name -> speakerID -> score
        var votes: [String: [String: Int]] = [:]
        for name in candidateNames {
            let target = name.lowercased().split(separator: " ").first.map(String.init) ?? name.lowercased()
            for (i, toks) in tokenized.enumerated() {
                let sayer = segments[i].speakerId
                for pos in toks.indices where toks[pos] == target {
                    if Self.isSelfIntro(tokens: toks, at: pos) {
                        votes[name, default: [:]][sayer, default: 0] += 3
                    } else if let addressed = Self.addressedSpeaker(
                        sayer: sayer, segIndex: i, segments: segments,
                        nonMeTurnIDs: nonMeTurnIDs, meIDs: meIDs
                    ) {
                        votes[name, default: [:]][addressed, default: 0] += 1
                    }
                }
            }
        }

        // Greedy assignment by descending score, unique name ⇄ unique speaker,
        // restricted to eligible target speakers.
        var ranked: [(name: String, speaker: String, score: Int)] = []
        for (name, perSpeaker) in votes {
            for (sp, score) in perSpeaker where eligibleIDs.contains(sp) && score > 0 {
                ranked.append((name, sp, score))
            }
        }
        ranked.sort { $0.score > $1.score }

        var assignment: [String: String] = [:]
        var usedNames = Set<String>()
        for entry in ranked {
            guard assignment[entry.speaker] == nil else { continue }
            let lower = entry.name.lowercased()
            guard !usedNames.contains(lower) else { continue }
            assignment[entry.speaker] = entry.name
            usedNames.insert(lower)
        }
        return assignment
    }

    /// The speaker being addressed when `sayer` speaks a name in `segIndex`.
    /// Two-party fast path: exactly two non-"me" speakers take turns and the
    /// sayer is one of them → it's the other. Otherwise the nearest adjacent
    /// turn by a different, non-"me" speaker (preferring the previous turn — you
    /// usually name the person you're responding to).
    nonisolated static func addressedSpeaker(
        sayer: String,
        segIndex: Int,
        segments: [MeetingTranscriptSegment],
        nonMeTurnIDs: [String],
        meIDs: Set<String>
    ) -> String? {
        if nonMeTurnIDs.count == 2, nonMeTurnIDs.contains(sayer) {
            return nonMeTurnIDs.first { $0 != sayer }
        }
        var offset = 1
        while offset <= 8 {
            for j in [segIndex - offset, segIndex + offset] where j >= 0 && j < segments.count {
                let cand = segments[j].speakerId
                if cand != sayer, !meIDs.contains(cand) { return cand }
            }
            offset += 1
        }
        return nil
    }

    /// True when the name at `pos` is the speaker naming themselves — "I'm Sam",
    /// "I am Sam", "this is Sam", "(my) name is Sam", or "Sam here".
    nonisolated static func isSelfIntro(tokens: [String], at pos: Int) -> Bool {
        if pos + 1 < tokens.count, tokens[pos + 1] == "here" { return true }
        let p1 = pos >= 1 ? tokens[pos - 1] : ""
        let p2 = pos >= 2 ? tokens[pos - 2] : ""
        let p3 = pos >= 3 ? tokens[pos - 3] : ""
        if p1 == "i'm" || p1 == "im" { return true }
        if p1 == "am", p2 == "i" { return true }
        if p1 == "is", p2 == "this" { return true }
        if p1 == "is", p2 == "name" || p3 == "name" { return true }
        return false
    }

    /// Lowercase word tokens (letters + apostrophes), so "I'm" survives as one
    /// token for the self-intro check.
    nonisolated static func tokenize(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
    }

    private nonisolated static func orderedUnique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for x in xs where !seen.contains(x) { seen.insert(x); out.append(x) }
        return out
    }

    // MARK: - Default-name detection

    /// True when `name` is still a diarizer default ("Me", "Other", or
    /// "Speaker N") rather than something a person chose. Inference only ever
    /// overwrites default (or previously-inferred) names.
    static func isDefaultName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n == "Me" || n == "Other" { return true }
        guard n.hasPrefix("Speaker ") else { return false }
        let rest = n.dropFirst("Speaker ".count)
        return !rest.isEmpty && rest.allSatisfy { $0.isNumber }
    }

    // MARK: - Prompt

    private static let nameExtractionPrompt = """
    You are given a conversation transcript. Each line is prefixed with a speaker label and timestamp, e.g. "[Speaker 1 · 0:12] …".

    Your only job: list the FIRST NAMES of the people actually TAKING PART in the conversation — the people who speak.

    A name counts when it is spoken in the transcript: a greeting, a self-introduction ("I'm Sam"), or one participant addressing or thanking another by name ("thanks, Sam", "what do you think, Sam?").

    - First names only.
    - Include a name only if it is actually spoken somewhere in the transcript.
    - Do NOT include people who are only talked ABOUT but never speak. Do NOT include character names, place names, brands, or companies.
    - Do NOT try to say which speaker label is which — only list the names.

    Output ONLY a JSON array of first names, for example: ["Sam", "Priya"]
    If you can't identify any participant names, output exactly: []
    """

    // MARK: - Parsing & validation

    /// Names from the model's reply. Primary shape is a JSON array of strings;
    /// as a hedge against a model that ignores the format and returns the old
    /// {label: name} object instead, we also harvest any object's string values.
    /// Surrounding prose / code fences are tolerated.
    private static func parseCandidateNames(_ raw: String) -> [String] {
        let cleaned = LLMTextUtilities.clean(raw)
        var names: [String] = []
        if let arr = firstJSONArray(in: cleaned) { names.append(contentsOf: arr) }
        for objStr in balancedJSONObjects(in: cleaned) {
            guard let data = objStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for v in obj.values { if let s = v as? String { names.append(s) } }
        }
        return names
    }

    /// First balanced `[ … ]` in `s` decoded as an array of strings (non-string
    /// entries dropped). Respects quoted strings so a bracket inside a value
    /// can't desync the scan. nil when there's no parseable array.
    private static func firstJSONArray(in s: String) -> [String]? {
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" else { i += 1; continue }
            var depth = 0
            var inString = false
            var escaped = false
            var j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "[" {
                    depth += 1
                } else if c == "]" {
                    depth -= 1
                    if depth == 0 {
                        let sub = String(chars[i...j])
                        if let data = sub.data(using: .utf8),
                           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                            return arr.compactMap { $0 as? String }
                        }
                        break
                    }
                }
                j += 1
            }
            i = j > i ? j + 1 : i + 1
        }
        return nil
    }

    /// Pull out each top-level balanced `{…}` substring, respecting quoted
    /// strings so a brace inside a value can't desync the matching. Returns them
    /// in document order.
    private static func balancedJSONObjects(in s: String) -> [String] {
        let chars = Array(s)
        var result: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0
            var inString = false
            var escaped = false
            var j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 { result.append(String(chars[i...j])); break }
                }
                j += 1
            }
            i = j > i ? j + 1 : i + 1
        }
        return result
    }

    /// Filler / pronoun / role words a small model sometimes returns as a
    /// "name". Names that survive must look like names, not these.
    private static let denylist: Set<String> = [
        "yeah", "yes", "no", "okay", "ok", "hi", "hello", "hey", "thanks",
        "thank", "me", "you", "i", "he", "she", "they", "we", "us", "them",
        "everyone", "everybody", "someone", "somebody", "all", "guys", "folks",
        "host", "guest", "speaker", "interviewer", "interviewee", "presenter",
        "moderator", "panelist", "panellist", "caller", "narrator", "unknown",
        "person", "people", "team", "the", "and", "mr", "mrs", "ms", "dr",
        "sir", "madam", "miss", "everybody's", "name",
    ]

    /// Trim wrapping punctuation, then accept only something name-shaped:
    /// 1–3 words, letters/space/hyphen/apostrophe/period only, 2–40 chars, not
    /// in the denylist. Lowercase tokens get a capital initial so "rory"
    /// becomes "Rory" without disturbing "McDonald" / "O'Brien".
    private static func sanitiseName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"'`*_.,;:()[]{}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let words = name.split(whereSeparator: { $0 == " " })
        guard (1...3).contains(words.count) else { return nil }
        guard name.count >= 2, name.count <= 40 else { return nil }

        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "-'. "))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let firstScalar = name.unicodeScalars.first, CharacterSet.letters.contains(firstScalar) else { return nil }
        if denylist.contains(name.lowercased()) { return nil }
        // Reject if every word is in the denylist (e.g. "the team").
        if words.allSatisfy({ denylist.contains($0.lowercased()) }) { return nil }

        // Capitalise an all-lowercase word's initial; leave mixed-case as-is.
        name = words.map { word -> String in
            let w = String(word)
            if w == w.lowercased(), let f = w.first {
                return f.uppercased() + w.dropFirst()
            }
            return w
        }.joined(separator: " ")
        return name
    }

    /// Lowercased set of spoken word tokens across all segments (letters +
    /// apostrophes only). Used to confirm a guessed name was actually said.
    private static func spokenWordSet(_ segments: [MeetingTranscriptSegment]) -> Set<String> {
        var set = Set<String>()
        for seg in segments {
            for token in seg.text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                set.insert(String(token))
            }
        }
        return set
    }
}
