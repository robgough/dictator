import SwiftUI
import AppKit

/// Usage — what the user has actually done with the app, as opposed to what the
/// app is (which is About's job).
///
/// Split out of `AboutPane` once the stats grew past half that file: two kinds
/// of content had ended up on one page, and someone opening About to check a
/// version number had to scroll past a fortnight of activity to reach it.
struct UsagePane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AboutStats()
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AboutStats: View {
    @State private var stats: UsageStats = .zero
    @State private var thisDeviceStats: UsageStats = .zero
    @State private var deviceCount: Int = 0
    @State private var currentStreak: Int = 0
    @State private var bestStreak: Int = 0
    @State private var recentDays: [(date: Date, count: Int)] = []

    var body: some View {
        AboutSection(title: "Your usage") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    StatsCard(
                        title: "Dictation",
                        systemImage: "waveform",
                        tint: .accentColor,
                        primaryValue: stats.dictationCount,
                        primaryLabel: stats.dictationCount == 1 ? "transcription" : "transcriptions",
                        averageValue: stats.averageDictationWords,
                        averageLabel: "avg words per transcription",
                        wordsIn: stats.dictationWordsIn,
                        wordsInLabel: "words spoken",
                        wordsOut: stats.dictationWordsOut,
                        wordsOutLabel: "words delivered"
                    )
                    StatsCard(
                        title: "Assistant",
                        systemImage: "wand.and.stars",
                        tint: .purple,
                        primaryValue: stats.assistantCount,
                        primaryLabel: stats.assistantCount == 1 ? "turn" : "turns",
                        averageValue: stats.averageAssistantInstructionWords,
                        averageLabel: "avg words per instruction",
                        wordsIn: stats.assistantWordsIn,
                        wordsInLabel: "instruction words",
                        wordsOut: stats.assistantWordsOut,
                        wordsOutLabel: "reply words"
                    )
                }
                if stats.dictationCount > 0 {
                    HabitCard(
                        currentStreak: currentStreak,
                        bestStreak: bestStreak,
                        wordsPerMinute: stats.wordsPerMinute,
                        days: recentDays
                    )
                }
                if stats.llmTokensIn + stats.llmTokensOut > 0 {
                    LLMTokenCard(
                        allTokensIn: stats.llmTokensIn,
                        allTokensOut: stats.llmTokensOut,
                        thisTokensIn: thisDeviceStats.llmTokensIn,
                        thisTokensOut: thisDeviceStats.llmTokensOut,
                        // This Mac's, never the pooled figure: generation speed
                        // describes the machine and the model, so averaging it
                        // with another Mac's would describe neither.
                        tokensPerSecond: thisDeviceStats.llmTokensPerSecond,
                        showsPerDevice: deviceCount > 1
                    )
                }
                // One line, whatever the device count: the "how do I pool
                // totals across Macs?" answer lives in General → Synced folder.
                Text("Counted on-device. No telemetry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            UsageStatsStore.shared.reload()
            stats = UsageStatsStore.shared.totals
            thisDeviceStats = UsageStatsStore.shared.thisDeviceStats
            deviceCount = UsageStatsStore.shared.deviceCount
            currentStreak = UsageStatsStore.shared.currentStreak
            bestStreak = UsageStatsStore.shared.bestStreak
            recentDays = UsageStatsStore.shared.recentDays(HabitCard.dayCount)
        }
    }
}

/// Streak, speaking rate, and the last quarter's activity.
///
/// Sits below the two flow cards because it cuts across them in a different
/// way: those answer "how much have I done", this answers "how is this going".
/// Orange so it reads as a third category next to the accent and purple cards
/// rather than an extension of either.
private struct HabitCard: View {
    let currentStreak: Int
    let bestStreak: Int
    let wordsPerMinute: Int?
    let days: [(date: Date, count: Int)]

    /// Thirteen weeks. Long enough to show a habit forming, short enough that
    /// the squares stay legible at the pane's width without scrolling.
    static let dayCount = 91

    private var tint: Color { .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "flame")
                    .font(.system(size: 11, weight: .semibold))
                Text("Habit")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .foregroundStyle(tint)

            HStack(alignment: .lastTextBaseline, spacing: 18) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("\(currentStreak)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(currentStreak == 1 ? "day streak" : "day streak")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 4) {
                    StatLine(value: "\(bestStreak)", label: bestStreak == 1 ? "day best" : "day best")
                    if let wordsPerMinute {
                        StatLine(value: "\(wordsPerMinute)", label: "words a minute spoken")
                    }
                }
            }

            ActivityStrip(days: days, tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

/// A column-per-week grid of day squares, oldest week on the left — the
/// contribution-graph shape, which people already know how to read.
private struct ActivityStrip: View {
    let days: [(date: Date, count: Int)]
    let tint: Color

    private static let square: CGFloat = 9
    private static let gap: CGFloat = 2

    /// Busiest day in the window, so the shading scales to how this particular
    /// person dictates rather than to a number picked in advance.
    private var peak: Int {
        max(1, days.map(\.count).max() ?? 1)
    }

    /// Split into columns of seven, in order. The first column may be short if
    /// the window doesn't start on a week boundary — it's a density strip, not
    /// a calendar, so the days simply run in sequence.
    private var weeks: [[(date: Date, count: Int)]] {
        stride(from: 0, to: days.count, by: 7).map { start in
            Array(days[start..<min(start + 7, days.count)])
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                VStack(spacing: Self.gap) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fill(for: day.count))
                            .frame(width: Self.square, height: Self.square)
                            .help(label(for: day))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Four steps rather than a continuous ramp: a gradient across a hundred
    /// tiny squares reads as noise, while a few discrete levels are
    /// comparable at a glance.
    private func fill(for count: Int) -> Color {
        guard count > 0 else { return Color.primary.opacity(0.06) }
        let level = Double(count) / Double(peak)
        switch level {
        case ..<0.34: return tint.opacity(0.35)
        case ..<0.67: return tint.opacity(0.6)
        default:      return tint.opacity(0.9)
        }
    }

    private func label(for day: (date: Date, count: Int)) -> String {
        let date = day.date.formatted(.dateTime.day().month(.abbreviated))
        if day.count == 0 { return "\(date): nothing" }
        return "\(date): \(day.count) \(day.count == 1 ? "dictation" : "dictations")"
    }
}

private struct StatsCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let primaryValue: Int
    let primaryLabel: String
    let averageValue: Int?
    let averageLabel: String
    let wordsIn: Int
    let wordsInLabel: String
    let wordsOut: Int
    let wordsOutLabel: String

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static func formatted(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Heading: small icon + title in the card's accent colour
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .foregroundStyle(tint)

            // Featured count + its label
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(Self.formatted(primaryValue))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(primaryLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Supporting rows. Average only renders once the user has
            // at least one record on this side — empty divisions read
            // as 0 which would be misleading.
            VStack(alignment: .leading, spacing: 4) {
                if let avg = averageValue {
                    StatLine(value: "\(Self.formatted(avg))", label: averageLabel)
                }
                StatLine(value: Self.formatted(wordsIn), label: wordsInLabel)
                StatLine(value: Self.formatted(wordsOut), label: wordsOutLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct StatLine: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Combined LLM token total — sits below the two main flow cards.
/// Cross-cuts both dictation cleanup passes and assistant turns, so
/// it doesn't belong inside either flow card. Teal so it reads as
/// related-but-different from the accent + purple above.
///
/// Two layouts:
///   - **Single-device** (`showsPerDevice` false): one featured
///     count with the input/output split underneath.
///   - **Multi-device** (`showsPerDevice` true): two columns side by
///     side comparing this device against all devices. Surfaces only
///     when more than one device has contributed — a one-device
///     install has no comparison to draw and would just look noisy.
private struct LLMTokenCard: View {
    let allTokensIn: Int
    let allTokensOut: Int
    let thisTokensIn: Int
    let thisTokensOut: Int
    let tokensPerSecond: Int?
    let showsPerDevice: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                Text("Local LLM")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 0)
                Text("tokens generated on-device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.teal)

            if showsPerDevice {
                HStack(alignment: .top, spacing: 24) {
                    LLMTokenColumn(
                        caption: "This device",
                        tokensIn: thisTokensIn,
                        tokensOut: thisTokensOut
                    )
                    LLMTokenColumn(
                        caption: "All devices",
                        tokensIn: allTokensIn,
                        tokensOut: allTokensOut
                    )
                }
            } else {
                LLMTokenColumn(
                    caption: nil,
                    tokensIn: allTokensIn,
                    tokensOut: allTokensOut
                )
            }

            if let tokensPerSecond {
                Text(showsPerDevice
                     ? "About \(tokensPerSecond.formatted()) tokens a second on this Mac."
                     : "About \(tokensPerSecond.formatted()) tokens a second.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.teal.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.teal.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct LLMTokenColumn: View {
    let caption: String?
    let tokensIn: Int
    let tokensOut: Int

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    private static func formatted(_ value: Int) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Text(Self.formatted(tokensIn + tokensOut))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 12) {
                StatLine(value: Self.formatted(tokensIn), label: "in")
                StatLine(value: Self.formatted(tokensOut), label: "out")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
