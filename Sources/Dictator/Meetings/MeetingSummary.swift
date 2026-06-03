import Foundation

/// LLM notes pass for meetings. Runs the user's currently-configured LLM
/// engine over the transcript and returns finished meeting notes as Markdown
/// (`MeetingNotes`) — the model authors the markdown directly; there's no
/// intermediate JSON schema.
///
/// Strategy:
///   - Short transcripts (≤ singlePassBudget tokens of estimated input):
///     one assist() call.
///   - Long transcripts: split into windowed chunks at segment boundaries,
///     write per-window markdown notes, then run a final reduce-pass that
///     merges the windows into one notes document.
///
/// We piggy-back on the engine's `assist()` method instead of inventing
/// a new protocol surface — `assist()` accepts an arbitrary system prompt
/// + selection + instruction, and the LLMTextUtilities.parseAssistant
/// fallback path returns the model's output verbatim when no `MODE:` marker
/// is present (which our prompt forbids).
///
/// Also still owns the short, cheap title-suggestion call (`suggestTitle`),
/// which is independent of the notes shape.
@MainActor
enum MeetingSummaryService {
    enum SummaryError: LocalizedError {
        case llmDisabled
        case parseFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .llmDisabled:
                return "Turn on an LLM in Settings → Models to generate summaries."
            case .parseFailed(let reason):
                return "Couldn't parse the summary — try again. (\(reason))"
            case .empty:
                return "The summary came back empty. Try again."
            }
        }
    }

    /// Conservative token budget for the input transcript that goes into a
    /// single LLM call. 6000 tokens ≈ 24000 chars ≈ ~30 minutes of dictated
    /// transcript at typical density — comfortably below both engines' input
    /// caps and leaves room for the system prompt + reply.
    private static let singlePassInputBudgetTokens = 6_000

    /// Below either of these a meeting is "very short" and takes the compact
    /// notes path — a 1–3 sentence summary plus action items only if present,
    /// no empty Discussion/Decisions scaffolding (see
    /// `builtinCompactMeetingSummaryPrompt`). Two independent triggers because
    /// each catches a case the other misses: a 40-second rapid-fire exchange
    /// can clear the word floor, and a 90-second mostly-silent recording can
    /// stay under it. Either being small is enough to call it short.
    private nonisolated static let compactMaxDurationSeconds: Double = 60
    private nonisolated static let compactMaxSpokenWords = 75

    /// Produce the finished markdown meeting notes using the currently-
    /// configured LLM engine. Stamps `modelID` with whichever engine ran and
    /// `generatedAt` with now, and marks the result `isFinal` — this is the
    /// end-of-meeting pass that supersedes any live first-pass.
    ///
    /// `meetingType` is the explicit override the caller wants this run
    /// biased toward — UI surfaces it via the "Summarise as ▾" picker.
    /// When nil (the auto-run call path from MeetingProcessor),
    /// we resolve in this order: `meta.meetingType` if the user has
    /// already picked a non-`.auto` type for this meeting, otherwise
    /// `settings.defaultMeetingType`.
    static func generateNotes(
        transcript: MeetingTranscript,
        meta: MeetingMeta,
        settings: DictatorSettings,
        meetingType: MeetingType? = nil
    ) async throws -> MeetingNotes {
        guard let engine = settings.activeLLMEngine() else {
            throw SummaryError.llmDisabled
        }
        try await engine.ensureReady()

        var resolvedType: MeetingType = {
            if let explicit = meetingType { return explicit }
            if meta.meetingType != .auto { return meta.meetingType }
            return settings.defaultMeetingType
        }()
        // Listen-only recording (no "Me" speaker — you weren't a participant)
        // left on auto-detect → treat it as a conversation/podcast, since none
        // of the participant-shaped types fit and the model often guesses wrong.
        if resolvedType == .auto, !meta.speakers.contains(where: { $0.isMe }) {
            resolvedType = .conversation
        }
        let modelID = engineModelID(settings: settings)
        let segments = transcript.segments
        guard !segments.isEmpty else { throw SummaryError.empty }

        // Very short recordings take the compact path: lighter system prompt
        // (Summary + optional Action items, no empty Discussion/Decisions
        // scaffolding) and a matching single-pass instruction. A short meeting
        // is always well under the single-pass budget, so map-reduce never
        // applies here. Long/normal meetings keep the full section contract.
        let isShort = isShortMeeting(durationSeconds: meta.durationSeconds, segments: segments)
        let prompt = isShort
            ? settings.effectiveCompactMeetingSummaryPrompt(for: resolvedType)
            : settings.effectiveMeetingSummaryPrompt(for: resolvedType)

        let rendered = renderSegments(segments, speakers: meta.speakers)
        let approxTokens = rendered.count / 4

        // The rough live outline (captured during the meeting) is fed in as a
        // completeness checklist — small models compress hard on the rewrite,
        // and the live pass is often the more complete record.
        let rawOutline = meta.rawNotes?.markdown.trimmingCharacters(in: .whitespacesAndNewlines)

        let raw: String
        if approxTokens <= singlePassInputBudgetTokens {
            raw = try await runSinglePass(
                engine: engine,
                systemPrompt: prompt,
                renderedTranscript: rendered,
                rawOutline: rawOutline,
                compact: isShort
            )
        } else {
            raw = try await runMapReduce(
                engine: engine,
                systemPrompt: prompt,
                segments: segments,
                speakers: meta.speakers,
                rawOutline: rawOutline
            )
        }

        let markdown = try cleanNotesMarkdown(raw)
        return MeetingNotes(
            markdown: markdown,
            modelID: modelID,
            generatedAt: Date(),
            isFinal: true
        )
    }

    // MARK: - Engine calls

    /// `compact` selects the short-meeting instruction wording to match the
    /// compact system prompt — a brief note (Summary + action items only if
    /// present) rather than the full section contract. The system prompt is
    /// already swapped by the caller; this only keeps the instruction in step.
    private static func runSinglePass(
        engine: any LLMEngine,
        systemPrompt: String,
        renderedTranscript: String,
        rawOutline: String?,
        compact: Bool
    ) async throws -> String {
        var selection = renderedTranscript
        var instruction = compact
            ? "Write a short note for the transcript above as Markdown, following the sections and rules in the system prompt. This is a very brief recording — keep it light and do not scaffold empty sections. Output ONLY the Markdown."
            : "Write the meeting notes for the transcript above as Markdown, following the sections and rules in the system prompt. Output ONLY the Markdown."
        if let rawOutline, !rawOutline.isEmpty {
            selection += "\n\n--- ROUGH LIVE OUTLINE (captured live with only coarse \"Me\"/\"Them\" labels; topic hints only — it may attribute points to the wrong person) ---\n\(rawOutline)"
            instruction = compact
                ? "Write a short note for the TRANSCRIPT above as Markdown, following the sections and rules in the system prompt. This is a very brief recording — keep it light and do not scaffold empty sections. A rough live outline follows the transcript — use it ONLY as a checklist of topics to make sure you covered; the TRANSCRIPT is the sole authority for who said, decided, or owns each point, so ignore any attribution the outline implies. Output ONLY the Markdown."
                : "Write the meeting notes for the TRANSCRIPT above as Markdown, following the sections and rules in the system prompt. A rough live outline follows the transcript — use it ONLY as a checklist of topics so you don't miss something the transcript supports. It was captured live with only coarse \"Me\"/\"Them\" labels and may credit points to the wrong person: the TRANSCRIPT (with its `[Name · mm:ss]` speaker prefixes) is the sole authority for who said, decided, or owns each point — ignore any attribution the outline implies. Output ONLY the Markdown."
        }
        let result = try await engine.assist(
            selection: selection,
            instruction: instruction,
            systemPrompt: systemPrompt,
            priorTurns: [],
            summary: nil,
            cancellation: { Task.isCancelled }
        )
        return result.text
    }

    /// Chunk the segments at speaker-turn boundaries until each chunk fits
    /// the input budget, write per-window markdown notes for each chunk, then
    /// run a final reduce-pass that merges the windows into one notes doc.
    private static func runMapReduce(
        engine: any LLMEngine,
        systemPrompt: String,
        segments: [MeetingTranscriptSegment],
        speakers: [MeetingMeta.Speaker],
        rawOutline: String?
    ) async throws -> String {
        let chunkBudgetChars = singlePassInputBudgetTokens * 4
        let chunks = chunk(segments: segments, maxCharsPerChunk: chunkBudgetChars)

        var partials: [String] = []
        partials.reserveCapacity(chunks.count)
        for chunk in chunks {
            try Task.checkCancellation()
            let rendered = renderSegments(chunk, speakers: speakers)
            let result = try await engine.assist(
                selection: rendered,
                instruction: "This is ONE window of a longer meeting. Write Markdown notes covering ONLY this window, using the same sections and rules as the system prompt. Output ONLY the Markdown.",
                systemPrompt: systemPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
            partials.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try Task.checkCancellation()

        // Reduce pass — feed the concatenated per-window notes back through
        // and ask for one merged Markdown document. The system prompt is
        // unchanged so the same section contract and attribution rules apply.
        var merged = partials.enumerated().map { idx, body in
            "WINDOW \(idx + 1) OF \(partials.count):\n\(body)"
        }.joined(separator: "\n\n---\n\n")

        var instruction = "The selection contains per-window Markdown notes from a long meeting, in chronological order. Merge them into a SINGLE set of Markdown notes in the section shape the system prompt specifies — one `## Summary` covering the whole meeting, then `## Discussion`/`## Decisions`/`## Action items`, owners preserved exactly. PRESERVE DETAIL: keep every distinct point from the windows; only collapse genuine duplicates. Do NOT shorten for brevity — a long meeting must yield thorough notes. Output ONLY the merged Markdown."
        if let rawOutline, !rawOutline.isEmpty {
            merged += "\n\n--- ROUGH LIVE OUTLINE (captured live with only coarse \"Me\"/\"Them\" labels; topic hints only — it may attribute points to the wrong person) ---\n\(rawOutline)"
            instruction = "The selection contains per-window Markdown notes from a long meeting, in chronological order, followed by a rough live outline captured during the meeting. Merge the windows into a SINGLE set of Markdown notes in the section shape the system prompt specifies — one `## Summary`, then `## Discussion`/`## Decisions`/`## Action items`, owners preserved exactly. PRESERVE DETAIL: keep every distinct point from the windows. Use the live outline ONLY as a checklist of topics so you don't drop a subject the windows covered — it was captured with coarse \"Me\"/\"Them\" labels and may credit points to the wrong person, so NEVER take an owner or attribution from it; the per-window notes (derived from the named transcript) are the sole authority for who said or owns what. Only collapse genuine duplicates; do NOT shorten for brevity. Output ONLY the merged Markdown."
        }

        let finalResult = try await engine.assist(
            selection: merged,
            instruction: instruction,
            systemPrompt: systemPrompt,
            priorTurns: [],
            summary: nil,
            cancellation: { Task.isCancelled }
        )
        return finalResult.text
    }

    // MARK: - Short-meeting detection

    /// Deterministic "is this a tiny recording?" test driving the compact
    /// notes path. True when the recording is under `compactMaxDurationSeconds`
    /// OR fewer than `compactMaxSpokenWords` words were spoken across all
    /// segments. `durationSeconds` can be 0 on a freshly-imported/partly-
    /// written meta, so we never rely on duration alone — the word count is the
    /// backstop. Whitespace-split word count matches how the budgets elsewhere
    /// reason about transcript size; it doesn't need to be exact, only stable.
    nonisolated static func isShortMeeting(
        durationSeconds: Double,
        segments: [MeetingTranscriptSegment]
    ) -> Bool {
        if durationSeconds > 0, durationSeconds < compactMaxDurationSeconds { return true }
        let words = segments.reduce(0) { acc, seg in
            acc + seg.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        return words < compactMaxSpokenWords
    }

    // MARK: - Chunking

    /// Walk segments and emit chunks bounded by `maxCharsPerChunk`. Never
    /// splits a single segment — a segment longer than the chunk budget
    /// becomes its own (oversized) chunk. The reduce pass still copes
    /// because every engine's input cap is well above one transcript
    /// segment's worth of text.
    nonisolated static func chunk(
        segments: [MeetingTranscriptSegment],
        maxCharsPerChunk: Int
    ) -> [[MeetingTranscriptSegment]] {
        guard !segments.isEmpty else { return [] }
        var chunks: [[MeetingTranscriptSegment]] = []
        var current: [MeetingTranscriptSegment] = []
        var currentChars = 0
        for seg in segments {
            let segChars = seg.text.count + 24  // 24 covers the speaker-time prefix
            if !current.isEmpty, currentChars + segChars > maxCharsPerChunk {
                chunks.append(current)
                current = []
                currentChars = 0
            }
            current.append(seg)
            currentChars += segChars
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Rendering

    /// Renders segments as `[Speaker · mm:ss] text` lines. The LLM uses the
    /// speaker label to attribute action-item ownership.
    nonisolated static func renderSegments(
        _ segments: [MeetingTranscriptSegment],
        speakers: [MeetingMeta.Speaker]
    ) -> String {
        let nameByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        return segments.map { seg -> String in
            let name = nameByID[seg.speakerId] ?? seg.speakerId
            return "[\(name) · \(formatTime(seg.start))] \(seg.text)"
        }.joined(separator: "\n")
    }

    private nonisolated static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Markdown cleanup

    /// Tidy the model's markdown reply into the notes body we persist. Strips
    /// surrounding ``` fences and stray preamble via `LLMTextUtilities.clean`,
    /// drops any leading `#` title the model emitted despite being told not to
    /// (we render the meeting title as the H1 ourselves), and trims. Validates
    /// that something notes-shaped survived — a non-empty body with at least a
    /// heading or a bullet — so a refusal or empty reply surfaces as an error
    /// the caller can fall back from rather than persisting junk.
    nonisolated static func cleanNotesMarkdown(_ raw: String) throws -> String {
        var text = LLMTextUtilities.clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop a leading H1 title line if the model added one — the UI/exporter
        // supply the title separately, and a duplicated title reads badly.
        if text.hasPrefix("# ") {
            let firstBreak = text.firstIndex(of: "\n")
            text = firstBreak
                .map { String(text[text.index(after: $0)...]) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        }

        guard !text.isEmpty else { throw SummaryError.empty }
        let looksLikeNotes = text.contains("#") || text.contains("- ") || text.contains("* ")
        guard looksLikeNotes else {
            throw SummaryError.parseFailed("output wasn't markdown notes")
        }
        return text
    }

    // MARK: - Title suggestion

    /// Short, cheap LLM call that proposes a 2–8 word title for the
    /// meeting. Returns nil when the model declined, returned garbage,
    /// or produced something that fails the quality gate — callers fall
    /// back to the existing date-format title in that case.
    ///
    /// Uses only the first ~chunkLeadChars of the transcript: most
    /// meetings open with enough context to title from (greetings,
    /// agenda mention, "today we want to talk about…"), and feeding the
    /// whole transcript wastes input tokens and risks the model
    /// regurgitating later content as a literal title.
    static func suggestTitle(
        transcript: MeetingTranscript,
        meta: MeetingMeta,
        settings: DictatorSettings
    ) async throws -> String? {
        guard let engine = settings.activeLLMEngine() else { return nil }
        try await engine.ensureReady()

        let segments = transcript.segments
        guard !segments.isEmpty else { return nil }

        let leadChars = 4_000
        let rendered = renderSegments(segments, speakers: meta.speakers)
        let lead = String(rendered.prefix(leadChars))

        let result: AssistantResult
        do {
            result = try await engine.assist(
                selection: lead,
                instruction: "Suggest a concise title for this meeting based on what's said. Output ONLY the title — nothing else.",
                systemPrompt: titleSuggestionPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
        } catch {
            return nil
        }

        return cleanCandidateTitle(result.text)
    }

    /// Standalone system prompt for the title-suggestion call. Kept
    /// internal (not a customisable user setting) — the surface is
    /// already crowded and the title prompt is narrow enough that the
    /// tuning headroom isn't worth a dedicated knob.
    private static let titleSuggestionPrompt = """
    You produce concise, descriptive titles for recorded meeting transcripts. You see only the opening of the transcript — enough to tell what the meeting is about.

    Output ONLY the title as a single line. 2–8 words. Title-case. No surrounding quotes. No trailing punctuation. No preamble like "Title:" or "Here is".

    If the opening is too short, too generic, or too unclear to title meaningfully (small-talk only, garbled speech, no discernible topic), output exactly the literal token: NOTITLE

    Examples:
    - A planning chat about a Q3 product launch → "Q3 Product Launch Planning"
    - Two engineers debugging a deployment → "Deployment Debugging Session"
    - "Hey, how are you, good, yeah, fine" → NOTITLE
    """

    /// Quality gate. Returns nil when the candidate fails — caller keeps
    /// the existing default title.
    nonisolated static func cleanCandidateTitle(_ raw: String) -> String? {
        let cleaned = LLMTextUtilities.clean(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Pull the first non-empty line — the model occasionally
            // appends "Here's why: …" commentary on a second line.
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !cleaned.isEmpty else { return nil }

        // Strip wrapping punctuation the prompt forbids but small models
        // sometimes still emit. Includes ASCII + smart quotes.
        let stripChars = CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}`*_.,;:")
        var candidate = cleaned.trimmingCharacters(in: stripChars)
            .trimmingCharacters(in: .whitespaces)

        // Drop a leading "Title:" / "Meeting title:" preamble.
        for prefix in ["Title:", "TITLE:", "title:", "Meeting title:", "Meeting Title:"] {
            if candidate.hasPrefix(prefix) {
                candidate = String(candidate.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Explicit "the model couldn't title this" signal.
        if candidate.uppercased() == "NOTITLE" { return nil }

        // Length + word-count gate. 3–80 chars, 1–12 words. Very long
        // outputs are almost always the model summarising rather than
        // titling.
        let chars = candidate.count
        guard chars >= 3, chars <= 80 else { return nil }
        let words = candidate.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 1, words.count <= 12 else { return nil }

        // Refusal / preamble patterns. If the model declined ("I cannot
        // create a title for this content") we'd otherwise paste that
        // straight into the title bar.
        let lower = candidate.lowercased()
        let refusalPatterns = [
            "i cannot", "i can't", "i'm sorry", "i am sorry",
            "as an ai", "as a language model",
            "unable to", "i won't", "i will not",
        ]
        if refusalPatterns.contains(where: { lower.hasPrefix($0) }) { return nil }

        // The model occasionally just emits "Meeting Title" as the literal
        // string — useless. Same for variations on the default we'd
        // already be using.
        let lowercaseIdentity = lower.replacingOccurrences(of: " ", with: "")
        if lowercaseIdentity == "meeting" || lowercaseIdentity == "meetingtitle" {
            return nil
        }

        return candidate
    }

    /// True when `title` matches the default "Meeting on YYYY-MM-DD HH:MM"
    /// format produced by `MeetingSession.defaultTitle`. Used to decide
    /// whether the auto-suggested title is safe to apply — if the user
    /// has already renamed (manually or via a previous auto-rename), we
    /// don't clobber that.
    nonisolated static func isDefaultMeetingTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Meeting on " + 16 chars of date/time = 27 chars exactly.
        guard trimmed.hasPrefix("Meeting on "), trimmed.count == 27 else { return false }
        let datePart = String(trimmed.dropFirst("Meeting on ".count))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: datePart) != nil
    }

    // MARK: - Engine id

    static func engineModelID(settings: DictatorSettings) -> String {
        switch settings.llmEngine {
        case .none:   return "none"
        case .apple:  return "apple-foundation"
        case .mlx:    return settings.llmModelID
        }
    }
}
