import SwiftUI
import AppKit
import Sparkle

struct AboutPane: View {
    let updater: SPUUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AboutHeader(updater: updater)
                AboutStats()
                AboutAuthor()
                AboutPrivacy()
                AboutCredits()
                AboutUtilities()
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Two one-line affordances. The setup wizard is permanent here because the
/// menu bar's Setup entry only shows while something is actually missing;
/// re-opening it is safe on a configured install and nothing is reset. The
/// models folder shortcut moved here from the Models pane's footnote.
private struct AboutUtilities: View {
    @Environment(AppState.self) private var state

    var body: some View {
        AboutSection(title: "Utilities") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("First-run wizard")
                        .help("Re-opens the setup walkthrough — permissions, transcription model, formatting LLM. Nothing is reset.")
                    Spacer()
                    Button("Open…") { state.showOnboarding() }
                        .controlSize(.small)
                }
                HStack {
                    Text("Models folder")
                        .help("~/Library/Application Support/Dictator/Models/")
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.root()])
                    }
                    .controlSize(.small)
                }
            }
            .font(.callout)
        }
    }
}

private struct AboutHeader: View {
    let updater: SPUUpdater

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "Version \(s) (\(b))"
        case let (s?, _): return "Version \(s)"
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 56, height: 56)
                Image(systemName: "waveform")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 26, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictator")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Local-first dictation for macOS. All speech and language models run on-device.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !version.isEmpty {
                    HStack(spacing: 10) {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        CheckForUpdatesButton(updater: updater)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// "Check for Updates…" button on the About pane. Mirrors Sparkle's
/// `canCheckForUpdates` state so it greys out while a check is in flight.
private struct CheckForUpdatesButton: View {
    let updater: SPUUpdater

    @State private var canCheck = true

    var body: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .controlSize(.small)
        .disabled(!canCheck)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
    }
}

/// Lifetime counters surfaced from `UsageStatsStore`. Reads `.totals`
/// which sums every device record in `stats.json` — so a user on
/// iCloud Drive sees the combined "across all my Macs" numbers, not
/// just this machine's contribution.
///
/// Layout: two cards side by side (dictation + assistant), each with
/// a featured count, an average, and the per-mode word totals. Colour
/// codes — accent for dictation (the dominant flow), purple for the
/// assistant — let the eye pick a card without reading every label.
private struct AboutStats: View {
    @State private var stats: UsageStats = .zero
    @State private var thisDeviceStats: UsageStats = .zero
    @State private var deviceCount: Int = 0

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
                if stats.llmTokensIn + stats.llmTokensOut > 0 {
                    LLMTokenCard(
                        allTokensIn: stats.llmTokensIn,
                        allTokensOut: stats.llmTokensOut,
                        thisTokensIn: thisDeviceStats.llmTokensIn,
                        thisTokensOut: thisDeviceStats.llmTokensOut,
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

private struct AboutAuthor: View {
    var body: some View {
        AboutSection(title: "Author") {
            VStack(alignment: .leading, spacing: 10) {
                Text("I'm **Rob Gough** — a tech advisor and fractional CTO offering a senior pair of eyes on tech strategy and what to build next, drawing on a long career in engineering and tech leadership. I'm also building **Stay Upfront**, a unified support and incident management tool for B2B SaaS companies.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dictator started as a personal itch. There are genuinely good free dictation tools for the Mac, but the moment I wanted more than the raw transcript — punctuation tidied, \"new paragraph\" honoured, a sensible bullet list when I rambled — that sat behind a subscription, even when the cleanup ran on a local model. The pieces to do it without one are already open and free: Whisper for the speech-to-text, a small Llama or Qwen for the cleanup, Apple Silicon to run them. Pulling them together turned out to be a fun problem.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("I now dictate most of my long-form writing with it. I hope you find it useful — and thank you for giving it a try.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
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
            }
        }
    }
}

private struct AboutPrivacy: View {
    var body: some View {
        AboutSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Everything that matters happens on your Mac. Audio is held in memory while you speak, then discarded. Transcripts, conversations, vocabulary, and your custom prompts live only under `~/Library/Application Support/Dictator/` on this machine.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Two things leave your Mac, both initiated by you: model downloads from Hugging Face when you pick one in Settings → Models, and update checks (which you can disable). No telemetry, no analytics, no account.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dictator is provided as-is. Please use it for what it's good at, and let me know when it isn't.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AboutCredits: View {
    private struct Credit: Identifiable {
        let id = UUID()
        let name: String
        let author: String
        let role: String
        let license: String
        let url: String
    }

    private let credits: [Credit] = [
        Credit(
            name: "WhisperKit",
            author: "Argmax, Inc.",
            role: "On-device Whisper speech-to-text",
            license: "MIT",
            url: "https://github.com/argmaxinc/argmax-oss-swift"
        ),
        Credit(
            name: "FluidAudio",
            author: "FluidInference",
            role: "Parakeet TDT speech-to-text on the Apple Neural Engine",
            license: "Apache 2.0",
            url: "https://github.com/FluidInference/FluidAudio"
        ),
        Credit(
            name: "MLX Swift LM",
            author: "Apple / mlx-explore",
            role: "MLX LLM runtime for the formatting, grammar, and structural passes",
            license: "MIT",
            url: "https://github.com/ml-explore/mlx-swift-lm"
        ),
        Credit(
            name: "MLX Swift",
            author: "Apple",
            role: "Tensor and array framework backing the LLM runtime",
            license: "MIT",
            url: "https://github.com/ml-explore/mlx-swift"
        ),
        Credit(
            name: "swift-transformers",
            author: "Hugging Face",
            role: "Tokenisers and model loading for the MLX pipeline",
            license: "Apache 2.0",
            url: "https://github.com/huggingface/swift-transformers"
        ),
        Credit(
            name: "KeyboardShortcuts",
            author: "Sindre Sorhus",
            role: "Global hotkey capture and recorder UI",
            license: "MIT",
            url: "https://github.com/sindresorhus/KeyboardShortcuts"
        ),
        Credit(
            name: "Whisper",
            author: "OpenAI",
            role: "Underlying speech-recognition model (weights downloaded on demand)",
            license: "MIT",
            url: "https://github.com/openai/whisper"
        ),
        Credit(
            name: "Parakeet TDT",
            author: "NVIDIA",
            role: "Underlying speech-recognition model (weights downloaded on demand)",
            license: "CC-BY-4.0",
            url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"
        ),
    ]

    var body: some View {
        AboutSection(title: "Built with") {
            VStack(spacing: 6) {
                ForEach(credits) { credit in
                    CreditRow(credit: credit)
                }
            }
        }
    }

    private struct CreditRow: View {
        let credit: Credit

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .font(.system(size: 13))
                    .frame(width: 16, alignment: .center)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Link(credit.name, destination: URL(string: credit.url)!)
                            .font(.system(size: 13, weight: .semibold))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(credit.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(credit.license)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.12))
                            )
                    }
                    Text(credit.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        }
    }
}

private struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
