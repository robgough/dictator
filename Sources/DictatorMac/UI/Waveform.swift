import SwiftUI

/// Live, decay-smoothed bar meter driven by RMS level updates.
struct Waveform: View {
    let level: Float
    var tint: Color = .accentColor
    /// When true, map level honestly on a dB scale with no boost or jitter —
    /// the meter reads flat on genuine silence and responds in proportion to
    /// real input. Meetings use this because the meter is the user's proof
    /// each side is being heard; the dictation HUD keeps the livelier,
    /// slightly-boosted default.
    var honest: Bool = false
    @State private var bars: [Double] = Array(repeating: 0.05, count: barCount)
    private static let barCount = 28

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 3
            let totalGap = gap * CGFloat(Self.barCount - 1)
            let barWidth = max(2, (size.width - totalGap) / CGFloat(Self.barCount))
            let midY = size.height / 2

            for (i, value) in bars.enumerated() {
                let h = max(2, CGFloat(value) * size.height)
                let x = CGFloat(i) * (barWidth + gap)
                let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                let shape = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                ctx.fill(shape, with: .color(tint))
            }
        }
        .frame(height: 52)
        .onChange(of: level, initial: false) { _, new in
            tick(with: Double(new))
        }
        .onAppear { tick(with: Double(level)) }
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue("\(Int((Self.normalized(Double(level), honest: honest)) * 100)) percent")
    }

    /// Map a raw RMS level to a 0…1 bar height. Honest mode uses a dB scale
    /// (−60 dB → 0, 0 dB → 1) so the meter is truthful; the default biases
    /// toward filling for legibility on the dictation HUD.
    private static func normalized(_ level: Double, honest: Bool) -> Double {
        if honest {
            let db = 20 * (log10(max(level, 0.0001)))
            return max(0.04, min(1.0, (db + 60) / 60))
        }
        return max(0.05, min(1.0, level * 1.7))
    }

    private func tick(with newLevel: Double) {
        // Shift existing bars left, append a fresh sample.
        var next = bars
        next.removeFirst()
        // Honest mode: truthful dB mapping, no jitter. Default: a touch of
        // randomness for life on the dictation HUD.
        let jitter = honest ? 1.0 : Double.random(in: 0.85...1.0)
        let target = Self.normalized(newLevel * jitter, honest: honest)
        next.append(target)

        // Light smoothing across neighbours so it doesn't look stuttery.
        var smoothed = next
        for i in 1..<(smoothed.count - 1) {
            smoothed[i] = (next[i - 1] * 0.2 + next[i] * 0.6 + next[i + 1] * 0.2)
        }
        withAnimation(.easeOut(duration: 0.06)) {
            bars = smoothed
        }
    }
}
