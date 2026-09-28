import SwiftUI

/// "Transcript › Polish (no changes) › Paragraphs" — `DictationRecord.trail`
/// as one line of text. Shared by the menu bar's recent rows and History so
/// the two can't describe the same dictation differently. Problems (a
/// rejected or failed pass) are orange; passes that ran and did nothing are
/// dimmed.
struct PassTrail: View {
    let record: DictationRecord

    var body: some View {
        record.trail.enumerated().reduce(Text("")) { line, item in
            let (index, step) = item
            let separator = index == 0 ? Text("") : Text(" › ").foregroundStyle(.tertiary)
            let label: Text = switch step.tone {
            case .normal: Text(step.label)
            case .quiet: Text(step.label).foregroundStyle(.tertiary)
            case .problem: Text(step.label).foregroundStyle(.orange)
            }
            return Text("\(line)\(separator)\(label)")
        }
    }
}

/// One line per pass outcome that has a reason, e.g. "Polish rejected: it
/// dropped part of what you said — kept the previous text".
struct PassOutcomeNotes: View {
    let record: DictationRecord

    var body: some View {
        let notes = record.outcomeNotes
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, outcome in
                    Label {
                        Text("\(outcome.pass) \(Self.verb(outcome)): \(outcome.detail ?? "")")
                    } icon: {
                        Image(systemName: outcome.isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                    }
                    .foregroundStyle(outcome.isProblem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
            }
        }
    }

    private static func verb(_ outcome: PassOutcome) -> String {
        switch outcome.kind {
        case .changed?: "ran"
        case .unchanged?: "made no changes"
        case .skipped?: "skipped"
        case .rejected?: "rejected"
        case .failed?: "failed"
        case nil: outcome.result
        }
    }
}
