import Foundation

/// The post-meeting coach report: a short, blunt LLM pass grounded entirely
/// in computed inputs — the deterministic metrics, the checklist outcomes,
/// the meeting type's rubric — with the meeting's notes as content context.
///
/// Deliberately NOT a transcript map-reduce (the blueprint's first sketch):
/// the notes are already a faithful compression of the meeting, the metrics
/// carry the behavioural truth, and a single cheap pass over those keeps the
/// report a seconds-long add-on to the notes generation it rides with.
///
/// PRIVATE like everything coach: the result lands on `meta.coach` and
/// renders only in the Coach tab — never the markdown mirrors or exports.
@MainActor
enum MeetingCoachReportService {
    enum ReportError: LocalizedError {
        case llmDisabled
        case noCoachData

        var errorDescription: String? {
            switch self {
            case .llmDisabled: "Turn on an LLM in Settings → Models to write the coach report."
            case .noCoachData: "This meeting has no coach data to report on."
            }
        }
    }

    /// Generate (or regenerate) the report and return the meeting's coach
    /// record with the report fields filled.
    static func generateReport(
        meta: MeetingMeta,
        settings: MeetingsSettings
    ) async throws -> MeetingCoachResult {
        guard var coach = meta.coach else { throw ReportError.noCoachData }
        guard let provider = ProviderRegistry.shared.provider(for: .final) else { throw ReportError.llmDisabled }
        try await provider.prepare()

        var blocks: [String] = []
        blocks.append("THEIR CONVERSATION METRICS:\n" + metricsBlock(coach.metrics, durationSeconds: meta.durationSeconds))
        if let outcomes = coach.checklist, !outcomes.isEmpty {
            blocks.append("KEY POINTS (computed outcomes):\n" + checklistBlock(outcomes))
        }
        if let rubric = resolveRubric(meta: meta, settings: settings) {
            blocks.append("RUBRIC for this kind of meeting:\n" + rubric)
        }
        if let notes = meta.notes?.markdown, !notes.isEmpty {
            blocks.append("MEETING NOTES (context only — judge the metrics, not the notes):\n" + String(notes.prefix(6000)))
        }

        let result = try await provider.assist(
            selection: blocks.joined(separator: "\n\n"),
            instruction: "Write the coach report on how Me handled this meeting.",
            systemPrompt: settings.effectiveMeetingCoachPrompt,
            cancellation: { false }
        )
        let markdown = LLMTextUtilities.clean(result.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { throw ReportError.noCoachData }

        coach.reportMarkdown = markdown
        coach.reportGeneratedAt = Date()
        coach.reportModelID = MeetingSummaryService.engineModelID()
        return coach
    }

    /// The rubric, in decision order: the preset the meeting ran with → the
    /// explicitly set meeting type → the type the notes pass detected
    /// (retroactive rubric — decided 2026-06-12) → none.
    private static func resolveRubric(meta: MeetingMeta, settings: MeetingsSettings) -> String? {
        var candidates: [MeetingTypeID] = []
        if let preset = meta.coach?.presetTypeID { candidates.append(MeetingTypeID(preset)) }
        if meta.meetingType != .auto { candidates.append(meta.meetingType) }
        if let detected = meta.notes?.meetingType { candidates.append(detected) }
        for id in candidates {
            let rubric = MeetingTypeRegistry.definition(for: id, settings: settings).coach?.rubric
            if let rubric, !rubric.isEmpty { return rubric }
        }
        return nil
    }

    private static func metricsBlock(_ m: CoachMetrics, durationSeconds: Double) -> String {
        var lines: [String] = []
        lines.append("- Meeting length: \(minutes(durationSeconds))")
        lines.append("- Your share of the talking: \(Int((m.talkShareMe * 100).rounded()))% (you \(minutes(m.myTalkSeconds)), others \(minutes(m.theirTalkSeconds)))")
        lines.append("- Your longest monologue: \(Int(m.longestMonologueSeconds))s")
        lines.append("- Times you interrupted: \(m.interruptionsByMe)")
        if let pace = m.paceWordsPerMinute {
            lines.append("- Your speaking pace: \(Int(pace.rounded())) words/min")
        }
        if let fillers = m.fillerWordsPerMinute {
            lines.append("- Filler words: ~\(String(format: "%.1f", fillers))/min of your speech (approximate)")
        }
        lines.append("- Questions you asked: \(m.myQuestionCount)")
        if m.longestSilenceSeconds >= 5 {
            lines.append("- Longest silence: \(Int(m.longestSilenceSeconds))s")
        }
        return lines.joined(separator: "\n")
    }

    private static func checklistBlock(_ outcomes: [CoachChecklistOutcome]) -> String {
        outcomes.map { o in
            let status: String
            if o.dismissed {
                status = "dismissed by Me"
            } else if let done = o.doneAtSeconds {
                status = "covered at \(minutes(done))"
            } else {
                status = "NOT covered"
            }
            let flagged = o.source == "adhoc" ? " (flagged mid-meeting at \(minutes(o.addedAtSeconds)))" : ""
            return "- \(o.text): \(status)\(flagged)"
        }
        .joined(separator: "\n")
    }

    private static func minutes(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }
}
