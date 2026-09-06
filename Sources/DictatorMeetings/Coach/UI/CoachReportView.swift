import SwiftUI

/// The Coach tab: the meeting's private feedback — deterministic metrics
/// up top, the key-points scorecard, then the blunt LLM report. The only
/// place coach data renders; nothing here reaches the notes, the markdown
/// mirrors, or any export.
struct CoachReportView: View {
    @Environment(MeetingsAppState.self) private var state
    @Bindable var session: MeetingSession

    var body: some View {
        if let coach = session.meta.coach {
            VStack(alignment: .leading, spacing: 18) {
                metricsGrid(coach.metrics)

                if let outcomes = coach.checklist, !outcomes.isEmpty {
                    scorecard(outcomes)
                }

                reportSection(coach)

                Label("Only you see this. The coach never appears in the meeting's notes or exports.", systemImage: "lock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No coach data for this meeting — the coach was off, or it was an import.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Metrics

    private func metricsGrid(_ m: CoachMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("How the conversation split", icon: "chart.pie")
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    metric("Your share", "\(Int((m.talkShareMe * 100).rounded()))%")
                    metric("Longest monologue", "\(Int(m.longestMonologueSeconds))s")
                    metric("Interruptions", "\(m.interruptionsByMe)")
                }
                GridRow {
                    metric("Pace", m.paceWordsPerMinute.map { "\(Int($0.rounded())) wpm" } ?? "–")
                    metric("Fillers", m.fillerWordsPerMinute.map { String(format: "~%.1f/min", $0) } ?? "–")
                    metric("Questions asked", "\(m.myQuestionCount)")
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Scorecard

    private func scorecard(_ outcomes: [CoachChecklistOutcome]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Key points", icon: "checklist")
            ForEach(Array(outcomes.enumerated()), id: \.offset) { _, outcome in
                HStack(spacing: 7) {
                    statusIcon(outcome)
                    Text(outcome.text)
                        .font(.system(size: 12))
                        .foregroundStyle(outcome.dismissed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .strikethrough(outcome.dismissed)
                    if outcome.source == "adhoc" {
                        Text("flagged mid-meeting")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ outcome: CoachChecklistOutcome) -> some View {
        if outcome.dismissed {
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
                .help("Dismissed during the meeting")
        } else if outcome.doneAtSeconds != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Covered")
        } else {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.orange)
                .help("Not covered")
        }
    }

    // MARK: - Report

    @ViewBuilder
    private func reportSection(_ coach: MeetingCoachResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Coach's read", icon: "figure.wave")
                Spacer()
                if session.coachReportRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(coach.reportMarkdown == nil ? "Write report" : "Re-run") {
                        Task { await session.generateCoachReport(settings: state.settings) }
                    }
                    .controlSize(.small)
                }
            }
            if let report = coach.reportMarkdown {
                MarkdownNotesView(markdown: report, speakers: [])
            } else if !session.coachReportRunning {
                Text(ProviderRegistry.shared.provider(for: .final) == nil
                     ? "Pick a model for the final notes on the Providers tab to get the coach's read on this meeting."
                     : "The report writes itself when you generate the meeting's notes — or hit Write report now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }
}
