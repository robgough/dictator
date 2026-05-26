import SwiftUI

/// Live, decay-smoothed bar meter driven by RMS level updates.
///
/// Ported from the macOS HUD's `Waveform` — pure SwiftUI (Canvas +
/// withAnimation), no AppKit deps, so the file is a near-verbatim copy
/// of the menu-bar version. The only iOS-specific tweak is making the
/// height a constructor parameter: the macOS HUD reserves 52pt for the
/// meter, but on iOS we render it next to the model-status chip in the
/// `recordingArea` header, which is closer to 30pt tall. Letting the
/// call site set the height keeps the bars visually centred on the
/// chip without forking the component.
///
/// The level smoothing biases toward filling the meter (multiplier of
/// 1.7) because dead-flat bars during real speech read worse than the
/// occasional top-clip — matches the Mac for consistency.
struct Waveform: View {
    let level: Float
    var tint: Color = .accentColor
    /// Bar-chart height. Pick something close to the height of the
    /// element you're sitting next to so the bars baseline-align.
    var height: CGFloat = 30
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
        .frame(height: height)
        .onChange(of: level, initial: false) { _, new in
            tick(with: Double(new))
        }
        .onAppear { tick(with: Double(level)) }
    }

    private func tick(with newLevel: Double) {
        // Shift existing bars left, append fresh sample with a touch of randomness for life.
        var next = bars
        next.removeFirst()
        let jitter = Double.random(in: 0.85...1.0)
        // Bias toward filling the meter for typical speech — loud syllables
        // pinning at 1.0 briefly is fine; visually-flat bars when someone
        // *is* talking is worse than occasional clipping at the top.
        let target = max(0.05, min(1.0, newLevel * jitter * 1.7))
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
