import Foundation

/// LLM summary pass for meetings. Runs the user's currently-configured
/// LLM engine over the transcript and parses a strict-JSON
/// MeetingSummaryResult out the other side.
///
/// Strategy:
///   - Short transcripts (≤ singlePassBudget tokens of estimated input):
///     one assist() call, parse JSON.
///   - Long transcripts: split into windowed chunks at segment boundaries,
///     summarise each into a partial JSON, then run a final reduce-pass
///     that merges the partials into the final MeetingSummaryResult.
///
/// We piggy-back on the engine's `assist()` method instead of inventing
/// a new protocol surface — `assist()` accepts an arbitrary system prompt
/// + selection + instruction, and the LLMTextUtilities.parseAssistant
/// fallback path returns the model's output verbatim when no `MODE:` marker
/// is present (which our prompt forbids).
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

    /// Produce a summary using the currently-configured LLM engine.
    /// Updates `generatedAt` to now and stamps `modelID` with whichever
    /// engine ran.
    static func summarise(
        transcript: MeetingTranscript,
        meta: MeetingMeta,
        settings: DictatorSettings
    ) async throws -> MeetingSummaryResult {
        guard let engine = settings.activeLLMEngine() else {
            throw SummaryError.llmDisabled
        }
        try await engine.ensureReady()

        let prompt = settings.effectiveMeetingSummaryPrompt
        let modelID = engineModelID(settings: settings)
        let segments = transcript.segments
        guard !segments.isEmpty else { throw SummaryError.empty }

        let rendered = renderSegments(segments, speakers: meta.speakers)
        let approxTokens = rendered.count / 4

        let jsonText: String
        if approxTokens <= singlePassInputBudgetTokens {
            jsonText = try await runSinglePass(
                engine: engine,
                systemPrompt: prompt,
                renderedTranscript: rendered
            )
        } else {
            jsonText = try await runMapReduce(
                engine: engine,
                systemPrompt: prompt,
                segments: segments,
                speakers: meta.speakers
            )
        }

        return try parse(jsonText: jsonText, modelID: modelID)
    }

    // MARK: - Engine calls

    private static func runSinglePass(
        engine: any LLMEngine,
        systemPrompt: String,
        renderedTranscript: String
    ) async throws -> String {
        let result = try await engine.assist(
            selection: renderedTranscript,
            instruction: "Summarise the meeting transcript above into the strict JSON shape the system prompt specifies. Output ONLY the JSON object.",
            systemPrompt: systemPrompt,
            priorTurns: [],
            summary: nil,
            cancellation: { Task.isCancelled }
        )
        return result.text
    }

    /// Chunk the segments at speaker-turn boundaries until each chunk fits
    /// the input budget, summarise each chunk into a JSON fragment, then
    /// run a final pass over the concatenated fragments.
    private static func runMapReduce(
        engine: any LLMEngine,
        systemPrompt: String,
        segments: [MeetingTranscriptSegment],
        speakers: [MeetingMeta.Speaker]
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
                instruction: "This is one window of a longer meeting. Produce the same strict JSON shape covering ONLY this window — decisions agreed in this window, action items captured in this window, narrative for this window only. Output ONLY the JSON object.",
                systemPrompt: systemPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
            partials.append(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        try Task.checkCancellation()

        // Reduce pass — feed the concatenated partials back through and
        // ask for a single merged JSON. The system prompt is unchanged
        // so the same schema rules apply.
        let merged = partials.enumerated().map { idx, body in
            "WINDOW \(idx + 1) OF \(partials.count):\n\(body)"
        }.joined(separator: "\n\n---\n\n")

        let finalResult = try await engine.assist(
            selection: merged,
            instruction: "The selection contains per-window JSON summaries from a long meeting. Merge them into a single JSON object in the same shape — deduplicate decisions and action items, combine narrative windows into one coherent 3–6-sentence narrative covering the whole meeting. Output ONLY the JSON object.",
            systemPrompt: systemPrompt,
            priorTurns: [],
            summary: nil,
            cancellation: { Task.isCancelled }
        )
        return finalResult.text
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

    // MARK: - Parsing

    /// Pulls the first `{ ... }` JSON object out of the LLM's reply and
    /// decodes it. Tolerant of preambles, trailing commentary, and
    /// surrounding markdown fences (LLMTextUtilities.clean strips the
    /// fences; the brace scan handles the rest).
    nonisolated static func parse(jsonText: String, modelID: String) throws -> MeetingSummaryResult {
        let cleaned = LLMTextUtilities.clean(jsonText)
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end else {
            throw SummaryError.parseFailed("no JSON object in output")
        }
        let body = String(cleaned[start...end])

        struct Partial: Decodable {
            let decisions: [String]?
            let actionItems: [MeetingSummaryResult.ActionItem]?
            let narrative: String?
        }
        do {
            let partial = try JSONDecoder().decode(Partial.self, from: Data(body.utf8))
            let decisions = (partial.decisions ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let actionItems = (partial.actionItems ?? []).compactMap { item -> MeetingSummaryResult.ActionItem? in
                let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else { return nil }
                let owner = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines)
                return MeetingSummaryResult.ActionItem(
                    owner: (owner?.isEmpty ?? true) ? nil : owner,
                    text: trimmedText
                )
            }
            let narrative = (partial.narrative ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if decisions.isEmpty, actionItems.isEmpty, narrative.isEmpty {
                throw SummaryError.empty
            }
            return MeetingSummaryResult(
                decisions: decisions,
                actionItems: actionItems,
                narrative: narrative,
                modelID: modelID,
                generatedAt: Date()
            )
        } catch let summaryError as SummaryError {
            throw summaryError
        } catch {
            throw SummaryError.parseFailed("\(error)")
        }
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

    private static func engineModelID(settings: DictatorSettings) -> String {
        switch settings.llmEngine {
        case .none:   return "none"
        case .apple:  return "apple-foundation"
        case .mlx:    return settings.llmModelID
        }
    }
}
