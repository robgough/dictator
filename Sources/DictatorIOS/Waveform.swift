import Observation
import SwiftUI

/// The live mic level, 0...1. Owned by `RecordingViewModel` and kept apart
/// from its `status`: the level changes dozens of times a second, and only
/// the meters should redraw when it does. Read it inside a meter, never in a
/// screen's body.
@MainActor
@Observable
final class LevelMeter {
    var level: Float = 0
}

/// Live, decay-smoothed bar meter driven by the mic level.
///
/// Ported from the macOS HUD's `Waveform`, with the height a constructor
/// parameter so the bars can match whatever they sit beside.
///
/// Drawn every display frame (up to 120 Hz on ProMotion) by a
/// `TimelineView`: a new sample scrolls in at a steady rate and every bar
/// eases toward its target each frame, so the motion is continuous rather
/// than stepping each time a level arrives. `withAnimation` can't do that —
/// it doesn't interpolate what a Canvas draws.
///
/// The level smoothing biases toward filling the meter (multiplier of
/// 1.7) because dead-flat bars during real speech read worse than the
/// occasional top-clip — matches the Mac for consistency.
struct Waveform: View {
    let meter: LevelMeter
    var tint: Color = .accentColor
    /// Bar-chart height. Pick something close to the height of the
    /// element you're sitting next to so the bars baseline-align.
    var height: CGFloat = 30
    @State private var bars: WaveformBars

    init(meter: LevelMeter, tint: Color = .accentColor, barCount: Int = 28, height: CGFloat = 30) {
        self.meter = meter
        self.tint = tint
        self.height = height
        _bars = State(initialValue: WaveformBars(count: max(3, barCount)))
    }

    var body: some View {
        TimelineView(.animation) { context in
            let values = bars.advance(to: context.date, level: Double(meter.level))
            Canvas { ctx, size in
                let gap: CGFloat = 3
                let totalGap = gap * CGFloat(values.count - 1)
                let barWidth = max(2, (size.width - totalGap) / CGFloat(values.count))
                let midY = size.height / 2

                for (i, value) in values.enumerated() {
                    let h = max(2, CGFloat(value) * size.height)
                    let x = CGFloat(i) * (barWidth + gap)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(tint))
                }
            }
        }
        .frame(height: height)
    }
}

/// The meter's bars between frames. A plain class (not observed) so
/// advancing it while drawing doesn't schedule another update.
@MainActor
final class WaveformBars {
    /// Where each bar is heading, oldest on the left.
    private var targets: [Double]
    /// What's drawn, easing toward `targets`.
    private var shown: [Double]
    private var lastFrame: Date?
    private var lastSample: Date?

    /// How often a new sample scrolls in from the right.
    private static let sampleInterval: TimeInterval = 1.0 / 24
    /// Time constant of the per-frame easing.
    private static let easing: TimeInterval = 0.06

    init(count: Int) {
        targets = Array(repeating: 0.05, count: count)
        shown = targets
    }

    func advance(to now: Date, level: Double) -> [Double] {
        let dt = lastFrame.map { min(0.1, max(0, now.timeIntervalSince($0))) } ?? 0
        lastFrame = now
        if lastSample.map({ now.timeIntervalSince($0) >= Self.sampleInterval }) ?? true {
            lastSample = now
            push(level)
        }
        let k = dt > 0 ? 1 - exp(-dt / Self.easing) : 0
        for i in shown.indices {
            shown[i] += (targets[i] - shown[i]) * k
        }
        return shown
    }

    private func push(_ level: Double) {
        targets.removeFirst()
        // A touch of randomness for life. Bias toward filling the meter for
        // typical speech — loud syllables pinning at 1.0 briefly is fine;
        // visually-flat bars when someone *is* talking is worse.
        let jitter = Double.random(in: 0.85...1.0)
        targets.append(max(0.05, min(1.0, level * jitter * 1.7)))
        // Light smoothing into the newest neighbour so it doesn't look stuttery.
        let n = targets.count
        if n >= 3 {
            targets[n - 2] = targets[n - 3] * 0.2 + targets[n - 2] * 0.6 + targets[n - 1] * 0.2
        }
    }
}
