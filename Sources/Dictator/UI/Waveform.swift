import SwiftUI

/// Live, decay-smoothed bar meter driven by RMS level updates.
struct Waveform: View {
    let level: Float
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
                let alpha = 0.55 + value * 0.45
                ctx.fill(shape, with: .color(.accentColor.opacity(alpha)))
            }
        }
        .frame(height: 36)
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
        let target = max(0.05, min(1.0, newLevel * jitter * 1.4))
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
