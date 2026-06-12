import SwiftUI

/// The island's meeting mode: a tiny ambient strip (talk-balance dot,
/// elapsed, share) that expands to one terse line when a nudge fires.
/// Reads the engine's 1 Hz snapshot; nothing here re-renders faster.
///
/// Phase 3 adds the click-to-expand checklist + quick-add; for now the only
/// interaction is the context menu's "Hide for this meeting".
struct CoachIslandContent: View {
    let engine: MeetingCoachEngine

    var body: some View {
        Group {
            if let nudge = engine.activeNudge {
                nudgeLine(nudge)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                ambientStrip
                    .transition(.opacity)
            }
        }
        .contextMenu {
            Button("Hide for this meeting") { engine.chipHidden = true }
        }
    }

    private var ambientStrip: some View {
        let s = engine.snapshot
        return HStack(spacing: 8) {
            Circle()
                .fill(balanceColor(share: s.talkShareMeWindow))
                .frame(width: 7, height: 7)
            Text(clock(s.elapsed))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
            if s.myTalkSeconds + s.theirTalkSeconds >= 30 {
                Text("You \(Int((s.talkShareMe * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
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
        case .monologue: "person.wave.2"
        case .interrupting: "hand.raised"
        case .dominating: "chart.pie"
        case .pace: "hare"
        }
    }

    /// Green while balanced, amber when leaning, orange past dominating —
    /// the windowed share, so it recovers when you do.
    private func balanceColor(share: Double) -> Color {
        switch share {
        case ..<0.55: .green
        case ..<0.70: .yellow
        default: .orange
        }
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
