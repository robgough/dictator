import SwiftUI

/// Compact live conversation metrics for the recording view's status band:
/// talk balance, pace, and a monologue timer that only surfaces once a run
/// is long enough to be worth noticing. Reads the engine's 1 Hz `snapshot`,
/// so it re-renders once a second — far below the meters' 10 fps.
///
/// Deliberately neutral phase-1 presentation: numbers and a balance bar, no
/// judgement. The nudge vocabulary (phase 2) is where opinion lives.
struct CoachMetricsStrip: View {
    let engine: MeetingCoachEngine

    /// Don't show a balance figure until there's this much total speech —
    /// "You 100%" two seconds into the call is noise, not signal.
    private static let minTalkSecondsToShow = 30.0
    /// Surface the monologue timer once my current run exceeds this.
    private static let monologueShowSeconds = 45.0

    var body: some View {
        let s = engine.snapshot
        let totalTalk = s.myTalkSeconds + s.theirTalkSeconds

        if totalTalk >= Self.minTalkSecondsToShow {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("You \(Int((s.talkShareMe * 100).rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    balanceBar(share: s.talkShareMe)
                    if let pace = s.paceWordsPerMinute {
                        Text("\(Int(pace.rounded())) wpm")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if s.currentMonologueSeconds >= Self.monologueShowSeconds {
                    Label(
                        "You've held the floor \(Int(s.currentMonologueSeconds))s",
                        systemImage: "person.wave.2"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Two-tone balance bar, my share in accent against their indigo —
    /// matching the meters' colour language directly above it.
    private func balanceBar(share: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(2, geo.size.width * share))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.indigo.opacity(0.5))
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
    }
}
