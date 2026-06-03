import Foundation

/// Conservative speaker-name inference. After diarization the non-"Me"
/// speakers are generic ("Speaker 1", "Speaker 2"); this runs one short LLM
/// pass that tries to recover their real names from what's actually said —
/// self-introductions ("I'm Rory", "Pat here") and direct address ("thanks,
/// Rory", "over to you, Sam").
///
/// It is deliberately timid. After the model answers, a deterministic
/// post-check:
///   - requires the guessed name to ACTUALLY occur as a spoken word in the
///     transcript (the strongest guard against an invented name),
///   - rejects filler / pronoun / role words that aren't names,
///   - refuses to give two speakers the same name,
///   - only ever touches speakers whose label is still the diarizer default
///     ("Speaker N" / "Other") or was set by a previous inference run — a name
///     the user typed by hand is never overwritten.
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
        // nothing is eligible (e.g. the user already named everyone), skip the
        // call entirely.
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

        let raw: String
        do {
            try await engine.ensureReady()
            let result = try await engine.assist(
                selection: rendered,
                instruction: "Identify the speakers' real names from the transcript above. Output ONLY the JSON object mapping each speaker label to a name.",
                systemPrompt: systemPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
            raw = result.text
        } catch {
            NSLog("[Dictator] Speaker-name inference failed: \(error)")
            return speakers
        }

        let mapping = parseMapping(raw)
        guard !mapping.isEmpty else { return speakers }

        let spokenTokens = spokenWordSet(segments)
        var result = speakers
        // Names already in play (manual or carried over) so we never collide.
        var takenNames = Set(speakers.map { $0.displayName.lowercased() })

        for (label, rawName) in mapping {
            guard let name = sanitiseName(rawName) else { continue }
            let lowerName = name.lowercased()
            // The first token of the name must actually be spoken somewhere in
            // the transcript — kills hallucinated names that never appear.
            let primaryToken = lowerName.split(separator: " ").first.map(String.init) ?? lowerName
            guard spokenTokens.contains(primaryToken) else { continue }
            // Don't reuse a name another speaker already holds.
            guard !takenNames.contains(lowerName) else { continue }
            // Match the model's label back to an eligible speaker by its
            // current display name (which is what it saw in the brackets).
            guard let idx = result.firstIndex(where: {
                !$0.isMe
                    && (isDefaultName($0.displayName) || $0.nameInferred)
                    && $0.displayName.caseInsensitiveCompare(label) == .orderedSame
            }) else { continue }
            // Skip a no-op rename.
            guard result[idx].displayName.caseInsensitiveCompare(name) != .orderedSame else { continue }
            takenNames.remove(result[idx].displayName.lowercased())
            takenNames.insert(lowerName)
            result[idx].displayName = name
            result[idx].nameInferred = true
        }
        return result
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

    private static let systemPrompt = """
    You identify the real names of the people speaking in a meeting transcript.

    Each line is prefixed with a speaker label and a timestamp, like:
    [Speaker 1 · 0:12] thanks, Rory, that's a great point
    [Speaker 2 · 0:18] no problem, happy to help

    Work out each label's real name ONLY from evidence in the spoken words:
    - self-introduction ("I'm Rory", "this is Pat", "Pat here")
    - being addressed by name ("thanks, Rory", "what do you think, Sam?", "over to you, Priya")
    - being clearly referred to by name by another speaker

    Rules:
    - Use the person's FIRST name (or a full name only if it's clearly stated as theirs).
    - NEVER guess a name from someone's role, company, or the topic. NEVER invent a name that isn't actually spoken in the transcript.
    - If you can't tell which label a spoken name belongs to, leave that label out.
    - Returning an empty object is correct and expected when no names are clearly identifiable — do not force a guess.

    Output ONLY a JSON object mapping the exact speaker label (the text inside the brackets, e.g. "Speaker 1") to the person's name. No commentary, no code fences.
    Example: {"Speaker 1": "Rory", "Speaker 2": "Pat"}
    If you can't confidently name anyone, output exactly: {}
    """

    // MARK: - Parsing & validation

    /// Pull the first `{ … }` object out of the model's reply and decode it as
    /// a string→string map. Lenient: ignores anything that isn't a string value
    /// and tolerates surrounding prose / fences.
    private static func parseMapping(_ raw: String) -> [String: String] {
        let cleaned = LLMTextUtilities.clean(raw)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start < end else { return [:] }
        let json = String(cleaned[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
        }
        return out
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
