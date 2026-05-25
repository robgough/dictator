import SwiftUI

/// About screen for the iOS app — version info, a short privacy
/// reassurance, and open-source credits. Pushed from the bottom of
/// `SettingsView`. Mobile-suited (a `List` of small sections, not the
/// macOS About pane's dense multi-card layout).
///
/// Version + build come from the bundle so the `MARKETING_VERSION` /
/// `CURRENT_PROJECT_VERSION` set in `project.yml` flow through without
/// being duplicated here.
struct AboutView: View {
    /// Cached on appear so the section doesn't re-read disk on every
    /// SwiftUI render pass. AboutView is push-navigated and short-lived,
    /// so a snapshot at present-time is plenty fresh.
    @State private var stats: UsageStats = .zero
    @State private var thisDeviceStats: UsageStats = .zero
    @State private var deviceCount: Int = 0
    /// Whether the user has opted into a shared folder. Drives the
    /// "Your usage" footer copy — the local-only line is misleading
    /// once stats are pooled across devices.
    @State private var sharedFolderConfigured: Bool = false

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Dictator"
    }

    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "Version \(s) (\(b))"
        case let (s?, _): return "Version \(s)"
        case let (_, b?): return "Build \(b)"
        default: return ""
        }
    }

    var body: some View {
        List {
            Section {
                // Logo + name/version/tagline as a centred header — same
                // shape as the standard iOS Settings → About header for
                // any system app. Rounded-rect mask matches the iOS
                // home-screen icon rendering (corner radius scales to
                // ~22% of the square edge, the conventional ratio).
                VStack(spacing: 12) {
                    Image("AboutLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                        .padding(.top, 4)

                    VStack(spacing: 4) {
                        Text(appName)
                            .font(.title2.weight(.semibold))
                        if !versionLine.isEmpty {
                            Text(versionLine)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text("Talk to your phone. Not the cloud.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            // Two cards, one per flow. The colour-coded layout makes
            // the dictation/assistant split scannable at a glance —
            // dropping the old flat row of four labels that conflated
            // the two flows.
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
            } header: {
                Text("Your usage")
            } footer: {
                // When a shared folder is connected, totals are summed
                // across every device writing to it (other iPhones, the
                // Mac app) — the local-only line would be misleading.
                if sharedFolderConfigured {
                    Text("Counted on-device with no telemetry. Because you've connected a shared folder in Settings, totals add up across every device sharing it.")
                } else {
                    Text("Counted locally on this device — nothing is reported.")
                }
            }

            Section {
                Text("Transcription runs locally with Parakeet on the Apple Neural Engine. If Apple Intelligence cleanup is enabled, it runs locally too, via the on-device foundation model. No audio, no transcripts, and no telemetry are transmitted off the device.")
                    .font(.callout)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Recordings live in memory only while you're speaking and are then discarded. History stays on this device.")
            }

            Section {
                CreditRow(
                    name: "FluidAudio",
                    detail: "FluidInference — Parakeet TDT speech-to-text on the ANE",
                    license: "Apache 2.0",
                    url: URL(string: "https://github.com/FluidInference/FluidAudio")!
                )
                CreditRow(
                    name: "Parakeet TDT v3",
                    detail: "NVIDIA — underlying speech-recognition model (weights downloaded on demand)",
                    license: "CC-BY-4.0",
                    url: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!
                )
            } header: {
                Text("Open Source")
            } footer: {
                Text("Thank you to the authors and maintainers.")
            }

            Section {
                AppleFrameworkRow(name: "SwiftUI", role: "User interface")
                AppleFrameworkRow(name: "AVFoundation", role: "Audio capture")
                AppleFrameworkRow(name: "CoreML", role: "Neural Engine inference")
                AppleFrameworkRow(name: "FoundationModels", role: "On-device cleanup model")
            } header: {
                Text("Apple Frameworks")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("I'm **Rob Gough** — a tech advisor and fractional CTO, offering a senior pair of eyes on tech strategy and what to build next, drawing on a long career in senior engineering and tech leadership. I'm also building **Stay Upfront**, a unified support and incident management tool for B2B SaaS companies.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Dictator started as a personal itch on the Mac. There are good free dictation tools, but the moment I wanted more than the raw transcript — punctuation tidied, \"new paragraph\" honoured, a sensible bullet list when I rambled — that functionality sat behind a subscription, even when the cleanup ran on a local model. The pieces to do it without one are already open and free: a small speech model for the words, an even smaller LLM for the cleanup, Apple Silicon to run them. Pulling them together turned out to be a fun problem.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("This is the same idea on the device in your pocket. Talk to it, get text out, no cloud round-trip. I hope you find it useful — and thank you for giving it a try.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Link(destination: URL(string: "https://dictator.robgough.net")!) {
                            Label("dictator.robgough.net", systemImage: "globe")
                        }
                        Link(destination: URL(string: "https://stayupfront.com")!) {
                            Label("stayupfront.com", systemImage: "bolt.horizontal")
                        }
                        Link(destination: URL(string: "mailto:hello@robgough.net")!) {
                            Label("hello@robgough.net", systemImage: "envelope")
                        }
                    }
                    .font(.callout)
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Author")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            UsageStatsStore.shared.reload()
            stats = UsageStatsStore.shared.totals
            thisDeviceStats = UsageStatsStore.shared.thisDeviceStats
            deviceCount = UsageStatsStore.shared.deviceCount
            sharedFolderConfigured = SharedFolderBookmark.isConfigured
        }
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

/// Combined LLM token total — sits below the two main flow cards.
/// Cross-cuts both dictation cleanup and assistant turns, so it
/// doesn't belong inside either flow card. Teal so it reads as
/// related-but-different from the accent + purple above.
///
/// Two layouts: a single-column featured count when only this
/// device has activity, or a side-by-side comparison of this
/// device vs. all devices when more than one is contributing
/// (via the shared folder).
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
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 12) {
                StatLine(value: Self.formatted(tokensIn), label: "in")
                StatLine(value: Self.formatted(tokensOut), label: "out")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows

private struct CreditRow: View {
    let name: String
    let detail: String
    let license: String
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Link(name, destination: url)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Text(license)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AppleFrameworkRow: View {
    let name: String
    let role: String

    var body: some View {
        HStack {
            Text(name)
                .font(.callout)
            Spacer()
            Text(role)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
