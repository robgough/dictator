import SwiftUI

/// Lifetime usage stats — pushed from Settings. Two coloured flow
/// cards (Dictation / Assistant) plus a third Local LLM card when
/// any LLM activity has been recorded. Stats are written via
/// `UsageStatsStore` from the recording / assist pipeline; this view
/// is read-only and snapshots on appear.
///
/// Lives in its own file rather than inside Settings or About
/// because both the data model (per-device records, shared-folder
/// aggregation) and the visual treatment (cards, colour coding) are
/// independent of either screen — and the page was big enough on
/// About to deserve a top-level entry on its own.
struct StatsView: View {
    @State private var stats: UsageStats = .zero
    @State private var thisDeviceStats: UsageStats = .zero
    @State private var deviceCount: Int = 0

    var body: some View {
        List {
            Section {
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
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
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
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if stats.llmTokensIn + stats.llmTokensOut > 0 {
                    LLMTokenCard(
                        allTokensIn: stats.llmTokensIn,
                        allTokensOut: stats.llmTokensOut,
                        thisTokensIn: thisDeviceStats.llmTokensIn,
                        thisTokensOut: thisDeviceStats.llmTokensOut,
                        showsPerDevice: deviceCount > 1
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } footer: {
                // Same shape as the macOS Stats footer: key off the
                // observable device count rather than guessing at
                // sync providers or sniffing the bookmark URL. If
                // more than one device has written records, the
                // folder is being shared somehow — that's the
                // truth, and we don't need to know how.
                if deviceCount > 1 {
                    Text("Counted on-device across \(deviceCount) devices — nothing is reported. Totals add up because your shared folder is reaching them all.")
                } else {
                    Text("Counted locally on this device — nothing is reported. Connect a shared folder in Settings to combine totals with your Mac or another device.")
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            UsageStatsStore.shared.reload()
            stats = UsageStatsStore.shared.totals
            thisDeviceStats = UsageStatsStore.shared.thisDeviceStats
            deviceCount = UsageStatsStore.shared.deviceCount
        }
    }
}

// MARK: - Cards

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

    /// Compact-name formatting (`1.2K`, `12K`, `1.2M`) to match the
    /// LLM card — heavy users push word totals into the millions and
    /// comma-separated digits were straining the card width. The
    /// granularity loss is acceptable; the stats screen is a glanceable
    /// "how much have I used this" summary, not a precise audit.
    private static func formatted(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .foregroundStyle(tint)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(Self.formatted(primaryValue))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(primaryLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let avg = averageValue {
                    StatLine(value: Self.formatted(avg), label: averageLabel)
                }
                StatLine(value: Self.formatted(wordsIn), label: wordsInLabel)
                StatLine(value: Self.formatted(wordsOut), label: wordsOutLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
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
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Combined LLM token total. Two layouts: single column when only
/// this device has activity, side-by-side when the shared folder
/// has more than one device contributing.
private struct LLMTokenCard: View {
    let allTokensIn: Int
    let allTokensOut: Int
    let thisTokensIn: Int
    let thisTokensOut: Int
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
                HStack(alignment: .top, spacing: 20) {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.teal.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.teal.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct LLMTokenColumn: View {
    let caption: String?
    let tokensIn: Int
    let tokensOut: Int

    /// Compact-name formatter: `999`, `1.2K`, `12K`, `1.2M`, `12M`,
    /// `1.2B`. LLM token totals run into the millions for daily users
    /// and the comma-separated layout was wrapping / overflowing the
    /// two-column card — the user only needs a rough "how heavy am I
    /// leaning on this" number, not seven digits of precision.
    private static func formatted(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
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
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 12) {
                StatLine(value: Self.formatted(tokensIn), label: "in")
                StatLine(value: Self.formatted(tokensOut), label: "out")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
