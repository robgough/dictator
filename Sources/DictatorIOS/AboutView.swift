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

            Section {
                StatRow(label: "Dictations", value: stats.dictationCount)
                StatRow(label: "Assistant turns", value: stats.assistantCount)
                StatRow(label: "Words spoken", value: stats.wordsIn)
                StatRow(label: "Words delivered", value: stats.wordsOut)
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
            sharedFolderConfigured = SharedFolderBookmark.isConfigured
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: Int

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(Self.formatter.string(from: NSNumber(value: value)) ?? "\(value)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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
