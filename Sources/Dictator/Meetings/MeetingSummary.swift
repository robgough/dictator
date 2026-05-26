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

    // MARK: - Engine id

    private static func engineModelID(settings: DictatorSettings) -> String {
        switch settings.llmEngine {
        case .none:   return "none"
        case .apple:  return "apple-foundation"
        case .mlx:    return settings.llmModelID
        }
    }
}
