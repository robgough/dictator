import SwiftUI

/// The island's meeting mode: a tiny ambient strip (talk-balance dot,
/// elapsed, share, checklist count) that expands to one terse line when a
/// nudge fires, and to the full checklist + quick-add on click. Reads the
/// engine's 1 Hz snapshot; nothing here re-renders faster.
struct CoachIslandContent: View {
    let engine: MeetingCoachEngine
    /// Bound to IslandContext.coachExpanded — the controller also watches it
    /// to grant the panel key-window status while the quick-add field needs
    /// typing.
    @Binding var expanded: Bool

    var body: some View {
        Group {
            if expanded {
                expandedPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let nudge = engine.activeNudge {
                nudgeLine(nudge)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                ambientStrip
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !expanded { expanded = true } }
        .contextMenu {
            Button("Hide for this meeting") { engine.chipHidden = true }
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                let s = engine.snapshot
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                Text("\(clock(s.elapsed))  ·  You \(Int((s.talkShareMe * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                if let pace = s.paceWordsPerMinute {
                    Text("·  \(Int(pace.rounded())) wpm")
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    expanded = false
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            CoachChecklistPanel(engine: engine, compact: true)
            Button("Hide coach for this meeting") { engine.chipHidden = true }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var ambientStrip: some View {
        let s = engine.snapshot
        return HStack(spacing: 8) {
            // RED, like every recording indicator everywhere — a green dot
            // here read as "weird recording light". Talk balance moved to
            // the share figure's colour instead.
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text(clock(s.elapsed))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
            if s.myTalkSeconds + s.theirTalkSeconds >= 30 {
                Text("You \(Int((s.talkShareMe * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(shareStyle(share: s.talkShareMeWindow))
            }
            if engine.hasChecklist {
                let done = engine.checklist.count(where: { !$0.isPending })
                Text("\(done)/\(engine.checklist.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func nudgeLine(_ nudge: CoachNudge) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: nudge.kind))
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
            Text(nudge.message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func icon(for kind: CoachNudge.Kind) -> String {
        switch kind {
        case .reminder: "checklist"
        case .monologue: "person.wave.2"
        case .interrupting: "hand.raised"
        case .dominating: "chart.pie"
        case .pace: "hare"
        case .askQuestion: "questionmark.bubble"
        }
    }

    /// The share figure stays quiet while balanced and warms as you lean on
    /// the conversation — the windowed share, so it recovers when you do.
    private func shareStyle(share: Double) -> AnyShapeStyle {
        switch share {
        case ..<0.55: AnyShapeStyle(.secondary)
        case ..<0.70: AnyShapeStyle(Color.yellow)
        default: AnyShapeStyle(Color.orange)
        }
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
