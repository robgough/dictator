import SwiftUI
import KeyboardShortcuts
import AVFoundation
import MLX
import Sparkle

struct SettingsView: View {
    let updater: SPUUpdater

    @Environment(AppState.self) private var state

    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            InputPane()
                .tabItem { Label("Input", systemImage: "mic") }
            ModelsPane()
                .tabItem { Label("Models", systemImage: "cpu") }
            PromptPane()
                .tabItem { Label("Prompt", systemImage: "text.alignleft") }
            DictionaryPane()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryPane()
                .tabItem { Label("History", systemImage: "clock") }
            AboutPane(updater: updater)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .environment(state)
    }
}

private struct AboutPane: View {
    let updater: SPUUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AboutHeader(updater: updater)
                AboutAuthor()
                AboutPrivacy()
                AboutCredits()
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct AboutAuthor: View {
    var body: some View {
        AboutSection(title: "Author") {
            VStack(alignment: .leading, spacing: 10) {
                Text("I'm **Rob Gough** — a tech advisor and fractional CTO, offering a senior pair of eyes on tech strategy and what to build next, drawing on a long career in senior engineering and tech leadership. I'm also building **Stay Upfront**, a unified support and incident management tool for B2B SaaS companies.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Dictator started as a personal itch. There are genuinely good free dictation tools for the Mac, but the moment I wanted more than the raw transcript — punctuation tidied, \"new paragraph\" honoured, a sensible bullet list when I rambled — that functionality sat behind a subscription, even when the cleanup ran on a local model. The pieces to do it without one are already open and free: Whisper for the speech-to-text, a small Llama or Qwen for the cleanup, Apple Silicon to run them. Pulling them together turned out to be a fun problem.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("I now dictate most of my long-form writing with it. I hope you find it useful — and thank you for giving it a try.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Link(destination: URL(string: "https://robgough.net")!) {
                        Label("robgough.net", systemImage: "globe")
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
                Text("Everything that matters happens on your Mac. Audio captured for transcription is held in memory while you're speaking and then discarded. Transcripts, conversations, vocabulary, and your custom prompts live only under `~/Library/Application Support/Dictator/` — on this machine.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Two things leave your Mac, both initiated by you: model downloads from Hugging Face when you pick one in **Settings → Models**, and periodic update checks (which you can disable). There's no telemetry, no analytics, and no account.")
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
            url: "https://github.com/argmaxinc/WhisperKit"
        ),
        Credit(
            name: "FluidAudio",
            author: "FluidInference",
            role: "Parakeet TDT speech-to-text on the Apple Neural Engine",
            license: "Apache 2.0",
            url: "https://github.com/FluidInference/FluidAudio"
        ),
        Credit(
            name: "MLX Swift Examples",
            author: "Apple / mlx-explore",
            role: "MLX LLM runtime for the formatting, grammar, and structural passes",
            license: "MIT",
            url: "https://github.com/ml-explore/mlx-swift-examples"
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
            VStack(alignment: .leading, spacing: 8) {
                Text("Dictator stands on the work of a number of open-source projects. Thank you to their authors and maintainers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
                VStack(spacing: 6) {
                    ForEach(credits) { credit in
                        CreditRow(credit: credit)
                    }
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

/// Open System Settings on the Keyboard pane. On macOS Sequoia the
/// Services checkbox list is buried behind a "Keyboard Shortcuts\u{2026}"
/// sheet \u{2014} no URL scheme jumps inside that sheet, and the legacy
/// `reveal anchor` AppleScript command was removed in Ventura. We tried
/// driving the click-through via Accessibility, but System Settings is
/// SwiftUI-internally so its AX titles sit on descendants of the
/// pressable element and the heuristic was unreliable. Better to just
/// land on the Keyboard pane and spell out the remaining two clicks
/// in the hint text.
@MainActor
private func openServicesSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
    NSWorkspace.shared.open(url)
}

/// Sort options for the dictionary list. Persisted at the view level
/// only \u{2014} re-opening Settings resets to the default. The
/// underlying `settings.vocabulary` array is always stored in
/// "as entered" order; sorting is purely a display concern.
private enum VocabularySortOrder: String, CaseIterable, Identifiable {
    case alphabetical
    case asEntered

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .asEntered:    "As entered"
        }
    }
}

private struct DictionaryPane: View {
    @Environment(AppState.self) private var state

    @State private var search: String = ""
    @State private var sort: VocabularySortOrder = .alphabetical
    @State private var showingHints: Bool = false
    /// New rows go to the top of the visible list and get auto-focused, so
    /// the user can start typing immediately. The id picked here is the
    /// one to pulse-highlight + focus on next render.
    @FocusState private var focusedFieldID: VocabularyEntry.ID?

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 12) {
            header
            toolbar($s.settings.vocabulary)
            list($s.settings.vocabulary)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom spellings & corrections")
                    .font(.headline)
                Text("Applied right after the formatter pass. Matches are word-aware and case-insensitive by default.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                showingHints.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Adding entries from outside Settings")
            .popover(isPresented: $showingHints, arrowEdge: .top) {
                hintsPopover
            }
            Spacer()
        }
    }

    // MARK: - Hints popover

    private var hintsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section 1: Quick-add from anywhere.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text("Select text in any app, right-click \u{2192} Services \u{2192} \u{201C}Learn Word in Dictator\u{2026}\u{201D} to add a rule without opening Settings.")
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()

            // Section 2: First-time Services setup.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                        .frame(width: 16)
                    Text("First-time setup")
                        .font(.system(size: 12, weight: .semibold))
                }
                (
                    Text("In ")
                    + Text("System Settings").bold()
                    + Text(", click ")
                    + Text("\u{201C}Keyboard Shortcuts\u{2026}\u{201D}").bold()
                    + Text(", select ")
                    + Text("Services").bold()
                    + Text(" in the sidebar, expand ")
                    + Text("Text").bold()
                    + Text(", and tick ")
                    + Text("\u{201C}Learn Word in Dictator\u{2026}\u{201D}").bold()
                    + Text(".")
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
                HStack {
                    Spacer()
                    Button {
                        openServicesSettings()
                    } label: {
                        Label("Open System Settings", systemImage: "arrow.up.forward.app")
                    }
                    .controlSize(.small)
                }
                .padding(.leading, 24)
            }
            Divider()

            // Section 3: What the per-row toggles mean. Glyphs match the
            // icons on each row's toggle buttons so users can correlate.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "switch.2")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                        .frame(width: 16)
                    Text("Per-rule options")
                        .font(.system(size: 12, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 6) {
                    optionRow(
                        icon: "textformat",
                        title: "Case-sensitive",
                        body: "On: only matches the exact casing you typed in \u{201C}Heard\u{201D}. Off (default): matches regardless of case \u{2014} \u{201C}github\u{201D} also catches \u{201C}Github\u{201D} and \u{201C}GITHUB\u{201D}."
                    )
                    optionRow(
                        icon: "text.word.spacing",
                        title: "Whole word only",
                        body: "On (default): only matches when the pattern stands alone, separated by spaces or punctuation. Off: matches even inside other words \u{2014} so \u{201C}api\u{201D} would also rewrite \u{201C}happier\u{201D}."
                    )
                }
                .padding(.leading, 24)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func optionRow(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Toolbar (search + sort + count + add)

    private func toolbar(_ vocabulary: Binding<[VocabularyEntry]>) -> some View {
        let total = vocabulary.wrappedValue.count
        let shown = filteredEntries(from: vocabulary.wrappedValue).count
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search dictionary\u{2026}", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            Text(countLabel(total: total, shown: shown))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Picker("Sort", selection: $sort) {
                ForEach(VocabularySortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Button {
                let new = VocabularyEntry(pattern: "", replacement: "")
                vocabulary.wrappedValue.insert(new, at: 0)
                state.save()
                // Switch to "as entered" so the brand-new empty row is
                // visible at the top regardless of alphabetic sort, then
                // focus its pattern field for immediate typing.
                sort = .asEntered
                search = ""
                focusedFieldID = new.id
            } label: {
                Label("Add", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }

    private func countLabel(total: Int, shown: Int) -> String {
        if total == 0 { return "" }
        if shown == total {
            return total == 1 ? "1 entry" : "\(total) entries"
        }
        return "\(shown) of \(total)"
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ vocabulary: Binding<[VocabularyEntry]>) -> some View {
        let entries = vocabulary.wrappedValue
        if entries.isEmpty {
            ContentUnavailableView(
                "Your dictionary is empty",
                systemImage: "character.book.closed",
                description: Text("Click **Add** to create your first rule. Example: pattern \"github\" \u{2192} replacement \"GitHub\".")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let visible = filteredEntries(from: entries)
            if visible.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visible) { entry in
                            CompactDictionaryRow(
                                entry: entryBinding(id: entry.id, in: vocabulary),
                                focused: $focusedFieldID,
                                onChange: { state.save() },
                                onRemove: {
                                    vocabulary.wrappedValue.removeAll { $0.id == entry.id }
                                    state.save()
                                }
                            )
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 280)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.04))
                )
            }
        }
    }

    // MARK: - Filtering & sorting

    private func filteredEntries(from source: [VocabularyEntry]) -> [VocabularyEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [VocabularyEntry]
        if q.isEmpty {
            filtered = source
        } else {
            filtered = source.filter {
                $0.pattern.lowercased().contains(q) || $0.replacement.lowercased().contains(q)
            }
        }
        switch sort {
        case .alphabetical:
            return filtered.sorted {
                $0.pattern.localizedCaseInsensitiveCompare($1.pattern) == .orderedAscending
            }
        case .asEntered:
            return filtered
        }
    }

    /// Binding that resolves an entry by id against the live source array.
    /// Necessary because `filteredEntries` returns a snapshot \u{2014}
    /// editing a row needs to mutate the canonical store, not the snapshot.
    private func entryBinding(id: VocabularyEntry.ID,
                              in array: Binding<[VocabularyEntry]>) -> Binding<VocabularyEntry> {
        Binding(
            get: {
                array.wrappedValue.first { $0.id == id }
                    ?? VocabularyEntry(id: id, pattern: "", replacement: "")
            },
            set: { newValue in
                if let idx = array.wrappedValue.firstIndex(where: { $0.id == id }) {
                    array.wrappedValue[idx] = newValue
                }
            }
        )
    }
}

/// Single-line row optimised for dictionaries with many entries. Toggles
/// for "case-sensitive" and "whole word" become icon toggle-buttons that
/// only render the affordance \u{2014} hover/help reveals the meaning. The
/// trash button fades in on hover so the row reads as data, not chrome.
private struct CompactDictionaryRow: View {
    @Binding var entry: VocabularyEntry
    @FocusState.Binding var focused: VocabularyEntry.ID?
    let onChange: () -> Void
    let onRemove: () -> Void

    @State private var hovering: Bool = false
    @FocusState private var localFocus: FocusedField?

    private enum FocusedField: Hashable { case pattern, replacement }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Heard", text: $entry.pattern)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .focused($localFocus, equals: .pattern)
                .onSubmit { onChange() }
                .onChange(of: entry.pattern) { _, _ in onChange() }
                .onChange(of: focused) { _, newID in
                    if newID == entry.id { localFocus = .pattern }
                }
                // .onChange doesn't fire if the row mounts *after* the
                // parent flips `focused` (which is what happens when Add
                // inserts a new row). Catch that case on appear.
                .onAppear {
                    if focused == entry.id { localFocus = .pattern }
                }

            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .font(.system(size: 10))

            TextField("Replacement", text: $entry.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity)
                .focused($localFocus, equals: .replacement)
                .onSubmit { onChange() }
                .onChange(of: entry.replacement) { _, _ in onChange() }

            Toggle(isOn: $entry.caseSensitive) {
                Image(systemName: "textformat")
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Case-sensitive")
            .onChange(of: entry.caseSensitive) { _, _ in onChange() }

            Toggle(isOn: $entry.wholeWord) {
                Image(systemName: "text.word.spacing")
                    .font(.system(size: 11, weight: .semibold))
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Whole word only")
            .onChange(of: entry.wholeWord) { _, _ in onChange() }

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 0.85 : 0)
            .frame(width: 18)
            .help("Delete rule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackground)
        )
        .onHover { hovering = $0 }
    }

    /// Subtle hover state so the row reads as interactive without
    /// surrounding every entry in a heavy card background like the
    /// previous design. Focus also tints the row so the user can see
    /// which entry is being edited.
    private var rowBackground: Color {
        if localFocus != nil { return Color.accentColor.opacity(0.10) }
        if hovering           { return Color.secondary.opacity(0.10) }
        return .clear
    }
}

private struct HistoryPane: View {
    @State private var history = DictationHistory.shared
    @State private var expanded: UUID?
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent dictations (last 7 days)")
                    .font(.headline)
                Spacer()
                Text("\(history.records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(history.records.isEmpty)
            }

            if history.records.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Recorded dictations will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(history.records) { record in
                            HistoryRow(
                                record: record,
                                isExpanded: expanded == record.id,
                                toggle: {
                                    expanded = expanded == record.id ? nil : record.id
                                },
                                remove: {
                                    history.remove(id: record.id)
                                    if expanded == record.id { expanded = nil }
                                }
                            )
                        }
                    }
                }
                .frame(minHeight: 280)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                history.clear()
                expanded = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded dictation. The dictation feature itself is unaffected.")
        }
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    let isExpanded: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: record.pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        .foregroundStyle(record.pasted ? Color.accentColor : .orange)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.final)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(Self.formatted(record.timestamp))
                            Text("·")
                            Text(record.inputDevice)
                            if let note = record.note {
                                Text("·")
                                Text(note)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedStages
                HStack {
                    Spacer()
                    Button(role: .destructive, action: remove) {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
    }

    @ViewBuilder
    private var expandedStages: some View {
        VStack(alignment: .leading, spacing: 6) {
            stageRow(label: "Raw (Whisper)", text: record.raw)
            if let f = record.formatted, f != record.raw {
                stageRow(label: "Formatted", text: f)
            }
            if let c = record.dictionaryCorrected {
                stageRow(label: "Dictionary-corrected", text: c)
            }
            if let t = record.tidied {
                stageRow(label: "Grammar-tidied", text: t)
            }
            if let r = record.restructured {
                stageRow(label: "Restructured", text: r)
            }
            if record.final != (record.restructured ?? record.tidied ?? record.dictionaryCorrected ?? record.formatted ?? record.raw) {
                stageRow(label: "Final (delivered)", text: record.final)
            }
        }
        .padding(.top, 4)
    }

    private func stageRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this stage")
                .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
    }

    private static func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

private struct InputPane: View {
    @State private var manager = AudioDeviceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MicTestCard(manager: manager)

            if manager.activeInputIsBluetooth() {
                BluetoothAdvisoryNote()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Priority order")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    // Real devices only — the System default sentinel is
                    // always "connected" by design, but counting it would
                    // make the ratio confusing ("3 of 3 connected" when the
                    // user has 2 real mics plugged in).
                    let realDevices = manager.knownDevices.filter { !$0.isSystemDefault }
                    let connectedCount = realDevices.filter { manager.isConnected($0.uid) }.count
                    Text("\(connectedCount) of \(realDevices.count) connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("Drag to reorder. Dictator uses the top-most **connected** device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if manager.knownDevices.isEmpty {
                    ContentUnavailableView(
                        "No input devices yet",
                        systemImage: "mic.slash",
                        description: Text("Plug in a microphone, then click Refresh.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
                } else {
                    // Anything ranked below "System default" never wins —
                    // the sentinel always counts as connected. Visually
                    // dim those rows so the user can see at a glance that
                    // they're effectively dead in the running order.
                    let sentinelIndex = manager.knownDevices.firstIndex(where: { $0.isSystemDefault }) ?? manager.knownDevices.count
                    let unreachableUIDs = Set(manager.knownDevices.dropFirst(sentinelIndex + 1).map(\.uid))
                    List {
                        ForEach(manager.knownDevices) { device in
                            DeviceRow(
                                device: device,
                                connected: manager.isConnected(device.uid),
                                isUnreachable: unreachableUIDs.contains(device.uid)
                            ) {
                                manager.forget(uid: device.uid)
                            }
                            .listRowSeparator(.visible)
                        }
                        .onMove { source, destination in
                            manager.move(from: source, to: destination)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: false))
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                }
            }
        }
    }
}

/// Combines the active-input header (device name, Refresh) with a live
/// meter row underneath. One card, one thing — the user can see at a
/// glance which mic Dictator is listening to *and* whether it's
/// actually picking sound up. The meter row hides when mic permission
/// hasn't been granted, so we don't show a stuck-at-zero bar that
/// reads as a bug.
/// Inline note explaining the trade-offs of using a Bluetooth mic. Surfaced
/// in the Input pane only when the currently-active device is a BT device.
/// Reason it's there: BT input forces macOS into HFP profile, which
/// downgrades headphone audio to mono 16 kHz and adds 2–5 s of warmup
/// latency before AVAudioEngine starts producing buffers. Users routinely
/// blame Dictator for both effects; surfacing the cause makes the trade-off
/// legible.
private struct BluetoothAdvisoryNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "headphones")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.orange)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bluetooth mic active")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("macOS switches Bluetooth headphones into a phone-call profile while recording. Expect a 2–5 s warmup at the start of each dictation, and music or system audio will sound thin and mono for as long as the recording is in flight. For snappier dictation and full-fidelity playback, promote the MacBook microphone (or any wired input) above your headphones in the list below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
        )
    }
}

/// Card replacing the old always-on live RMS meter. The user explicitly
/// triggers a short test recording, we capture, transcribe, and show
/// what the active ASR engine actually heard. That answers the question
/// the meter only hinted at ("is my mic working?") — *and* tells the
/// user how their voice is being decoded, which is the actually-useful
/// information when tuning models/devices.
///
/// Side-benefit: no continuous AVAudioEngine running while Settings is
/// open. Previously the meter's engine fought `AudioRecorder` for the
/// input device on single-client mics (Yeti / Bluetooth) and caused
/// occasional hangs at hotkey press.
private struct MicTestCard: View {
    let manager: AudioDeviceManager

    @Environment(AppState.self) private var state
    @State private var recorder = AudioRecorder()
    @State private var phase: Phase = .idle
    @State private var liveLevel: Float = 0
    @State private var lastResult: String?
    @State private var lastError: String?

    private enum Phase: Equatable {
        case idle
        case warmingUp
        case recording
        case transcribing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACTIVE INPUT")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(manager.activeInputDeviceName())
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button {
                    manager.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            testRow

            if let result = lastResult {
                resultBlock(result)
            } else if let error = lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Speak a sentence after pressing the button — we'll show you what the active engine transcribes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .onAppear { wireUpRecorder() }
        .onDisappear {
            // If the user navigates away mid-test, drop whatever is
            // captured so the engine isn't stuck holding the mic.
            recorder.cancelStart()
            _ = recorder.stop()
        }
    }

    @ViewBuilder private var testRow: some View {
        HStack(spacing: 12) {
            Button(action: toggle) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(phase == .warmingUp || phase == .transcribing)
            .keyboardShortcut(.defaultAction)

            switch phase {
            case .idle:
                EmptyView()
            case .warmingUp:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Connecting microphone…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .recording:
                Waveform(level: liveLevel)
                    .frame(maxWidth: .infinity)
            case .transcribing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing with \(engineLabel)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func resultBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("HEARD VIA \(engineLabel.uppercased())")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var buttonTitle: String {
        switch phase {
        case .idle: return lastResult == nil ? "Test microphone" : "Test again"
        case .warmingUp: return "Connecting…"
        case .recording: return "Stop"
        case .transcribing: return "Transcribing…"
        }
    }

    private var buttonIcon: String {
        switch phase {
        case .idle: return "mic.fill"
        case .warmingUp: return "antenna.radiowaves.left.and.right"
        case .recording: return "stop.fill"
        case .transcribing: return "waveform.badge.magnifyingglass"
        }
    }

    private var engineLabel: String {
        switch state.settings.transcriptionEngine {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        }
    }

    private func wireUpRecorder() {
        recorder.onLevel = { level in liveLevel = level }
        recorder.onReady = {
            // Mic is genuinely capturing; flip from warmingUp to recording.
            if phase == .warmingUp { phase = .recording }
        }
        recorder.onStartFailed = { error in
            phase = .idle
            lastResult = nil
            lastError = error.localizedDescription
        }
        recorder.onUnexpectedStop = { msg in
            phase = .idle
            lastResult = nil
            lastError = msg
        }
    }

    private func toggle() {
        switch phase {
        case .idle:
            lastResult = nil
            lastError = nil
            liveLevel = 0
            phase = .warmingUp
            recorder.start()
        case .recording:
            let samples = recorder.stop()
            // Match Pipeline's threshold (< 0.5 s at 16 kHz) — anything
            // shorter is almost certainly a misclick rather than speech.
            guard samples.count >= 8_000 else {
                phase = .idle
                lastError = "Too short — speak for at least a second."
                return
            }
            phase = .transcribing
            Task { await runTranscription(samples: samples) }
        case .warmingUp, .transcribing:
            break
        }
    }

    private func runTranscription(samples: [Float]) async {
        let settings = state.settings
        let engine: any ASREngine
        let modelID: String
        switch settings.transcriptionEngine {
        case .whisper:
            engine = TranscriptionServiceHolder.shared
            modelID = settings.whisperModelID
        case .parakeet:
            engine = ParakeetServiceHolder.shared
            modelID = settings.parakeetModelID
        }
        do {
            try await engine.ensureLoaded(modelID: modelID)
            let text = try await engine.transcribe(samples: samples, modelID: modelID)
            lastError = nil
            lastResult = text.isEmpty ? "(no speech detected)" : text
            phase = .idle
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            lastResult = nil
            phase = .idle
        }
    }
}

private struct DeviceRow: View {
    let device: AudioDevice
    let connected: Bool
    /// Ranked below the System default sentinel, so it would never be
    /// chosen — the sentinel always counts as connected and short-circuits
    /// the priority walk. Rendered dimmed so the user can spot it at a
    /// glance and drag it above the sentinel if they want it to matter.
    let isUnreachable: Bool
    let forget: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(connected: connected)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    if isUnreachable {
                        Text("Below System default — never used")
                    } else if device.isSystemDefault {
                        Text("Follows the macOS Sound preferences")
                    } else {
                        if let manufacturer = device.manufacturer, !manufacturer.isEmpty, manufacturer != "Apple" {
                            Text(manufacturer)
                            Text("·")
                                .foregroundStyle(.tertiary)
                        }
                        Text(connected ? "Connected" : "Last seen \(Self.relative(device.lastSeen))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            // The System default sentinel is structural — there's no
            // meaningful "forget" action, so the button just disappears
            // for that row.
            if !device.isSystemDefault {
                Button {
                    forget()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hovering ? Color.red.opacity(0.85) : .secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
                .help("Forget this device")
                .onHover { hovering = $0 }
            }
        }
        .padding(.vertical, 6)
        .opacity(isUnreachable ? 0.45 : 1)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct StatusDot: View {
    let connected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(connected ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
                .frame(width: 20, height: 20)
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 8, height: 8)
        }
        .accessibilityLabel(connected ? "Connected" : "Disconnected")
    }
}

private struct GeneralPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var s = state
        Form {
            Section("Permissions") {
                AccessibilityStatusRow()
                MicrophoneStatusRow()
            }
            Section("Your name") {
                TextField("e.g. Rob Gough", text: $s.settings.userName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.save() }
                    .onChange(of: s.settings.userName) { _, _ in state.save() }
                SectionFootnote("Used to bias transcription toward the correct spelling of your name, and so the assistant signs drafts as you (emails, replies, messages). Leave blank if you'd rather not set one.")
            }
            Section("Dictation hotkey") {
                Picker("Trigger", selection: $s.settings.triggerMode) {
                    ForEach(TriggerMode.allCases.filter { mode in
                        // Hide whatever the assistant trigger is currently using so
                        // the two hotkeys can't collide on the same physical key.
                        // `.keyboardShortcut` is exempt — different `Name`s can be
                        // bound to different combos independently.
                        mode == .keyboardShortcut || mode != s.settings.assistantTriggerMode
                    }) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: s.settings.triggerMode) { _, _ in state.save() }

                if s.settings.triggerMode == .keyboardShortcut {
                    HStack {
                        Text("Push-to-talk")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleDictation)
                        Button("Reset") {
                            state.resetDictationKeyboardShortcut()
                        }
                        .controlSize(.small)
                    }
                    SectionFootnote("Hold the shortcut to record, release to transcribe. Use **Reset** if the recorder gets cleared.")
                } else {
                    SectionFootnote("Hold the **\(s.settings.triggerMode.label)** key to dictate. Release to transcribe.")
                }
            }
            Section("Assistant Mode hotkey") {
                Picker("Trigger", selection: $s.settings.assistantTriggerMode) {
                    ForEach(TriggerMode.allCases.filter { mode in
                        mode == .keyboardShortcut || mode != s.settings.triggerMode
                    }) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: s.settings.assistantTriggerMode) { _, _ in state.save() }

                if s.settings.assistantTriggerMode == .keyboardShortcut {
                    HStack {
                        Text("Hold-to-assist")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleAssistant)
                        Button("Reset") {
                            state.resetAssistantKeyboardShortcut()
                        }
                        .controlSize(.small)
                    }
                } else {
                    SectionFootnote("Hold the **\(s.settings.assistantTriggerMode.label)** key with text selected to dictate an instruction. The LLM decides whether to replace your selection or copy the result to the clipboard.")
                }
            }
            Section("Behaviour") {
                Toggle("Paste into focused app automatically", isOn: $s.settings.pasteAutomatically)
                    .onChange(of: s.settings.pasteAutomatically) { _, _ in state.save() }
                Toggle("Play feedback sounds", isOn: $s.settings.playSounds)
                    .onChange(of: s.settings.playSounds) { _, _ in state.save() }
                Toggle("Pre-load models on launch", isOn: $s.settings.preloadModelsOnLaunch)
                    .onChange(of: s.settings.preloadModelsOnLaunch) { _, on in
                        state.save()
                        if on { state.preloadModels() }
                    }
                SectionFootnote("Loads Whisper and the LLM into memory at launch (~3 GB resident). First dictation is then instant.")

                let llmDisabled = s.settings.llmModelID == ModelCatalog.noneLLMID

                Toggle("Tidy grammar (third pass)", isOn: $s.settings.grammarPassEnabled)
                    .onChange(of: s.settings.grammarPassEnabled) { _, _ in state.save() }
                    .disabled(llmDisabled)
                Stepper(value: $s.settings.grammarPassMaxEditFraction, in: 0.05...0.40, step: 0.05) {
                    HStack {
                        Text("Discard if more than")
                        Spacer()
                        Text("\(Int(s.settings.grammarPassMaxEditFraction * 100))% of words change")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: s.settings.grammarPassMaxEditFraction) { _, _ in state.save() }
                .disabled(!s.settings.grammarPassEnabled || llmDisabled)
                SectionFootnote("Fixes obvious grammar errors (contractions, agreement, duplicate words). The pass is rejected if too many words change.")

                Toggle("Restructure long dictations into paragraphs / lists", isOn: $s.settings.structuralPassEnabled)
                    .onChange(of: s.settings.structuralPassEnabled) { _, _ in state.save() }
                    .disabled(llmDisabled)
                Stepper(value: $s.settings.structuralPassMinWords, in: 10...200, step: 5) {
                    HStack {
                        Text("Trigger when transcript reaches")
                        Spacer()
                        Text("\(s.settings.structuralPassMinWords) words")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: s.settings.structuralPassMinWords) { _, _ in state.save() }
                .disabled(!s.settings.structuralPassEnabled || llmDisabled)
                SectionFootnote("Adds paragraph breaks and bullet lists for longer dictations. The pass is rejected if it changes any of your words.")

                if llmDisabled {
                    SectionFootnote("LLM passes are disabled because **Formatting LLM → None** is selected in the Models tab.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccessibilityStatusRow: View {
    @State private var granted: Bool = TextInjector.hasAccessibilityPermission()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Accessibility").fontWeight(.medium)
                    Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(granted ? .green : .orange)
                        .font(.caption)
                }
                Text(granted
                     ? "Granted — Dictator can paste into the focused app."
                     : "Not granted — Dictator will copy to clipboard but cannot paste. Click Enable to register Dictator with macOS, then toggle it on in Accessibility.")
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Spacer()
            if !granted {
                // Two-step gesture in one click: trigger the AX trust prompt
                // (which adds Dictator to the Accessibility list in macOS's
                // database — without this the user can't find us in
                // System Settings), then surface the Settings page so they
                // have somewhere to flip the toggle. The AX prompt also pops
                // a system dialog with its own "Open System Preferences"
                // button, which is redundant but harmless.
                Button("Enable") {
                    TextInjector.requestAccessibilityPrompt()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.callout)
        .onReceive(pollTimer) { _ in
            granted = TextInjector.hasAccessibilityPermission()
        }
    }
}

private struct MicrophoneStatusRow: View {
    @State private var status: AVAuthorizationStatus = MicPermission.status()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Microphone").fontWeight(.medium)
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.caption)
                }
                Text(statusDescription)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Spacer()
            actionButton
        }
        .font(.callout)
        .onReceive(pollTimer) { _ in
            status = MicPermission.status()
        }
    }

    private var statusIcon: String {
        switch status {
        case .authorized: "checkmark.seal.fill"
        case .denied, .restricted: "exclamationmark.triangle.fill"
        case .notDetermined: "questionmark.circle.fill"
        @unknown default: "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized: .green
        case .denied, .restricted: .orange
        case .notDetermined: .secondary
        @unknown default: .secondary
        }
    }

    private var statusDescription: String {
        switch status {
        case .authorized:
            return "Granted — Dictator can hear you."
        case .denied, .restricted:
            return "Denied — dictation cannot record audio. Click Open Settings, then enable Dictator under Microphone."
        case .notDetermined:
            return "Not yet requested. Click Request to ask macOS for mic access."
        @unknown default:
            return "Unknown status."
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch status {
        case .notDetermined:
            // Triggers the OS prompt + registers Dictator in the Microphone
            // privacy list. Without this, the user only sees Dictator in
            // System Settings after the first dictation lazily fires the
            // request — bad first-run UX.
            Button("Request") {
                MicPermission.request { granted in
                    Task { @MainActor in
                        status = MicPermission.status()
                        // Belt + braces: a denial from the OS prompt still
                        // leaves us in `.denied`, where the user needs the
                        // Settings page to undo it.
                        if !granted {
                            openMicrophoneSettings()
                        }
                    }
                }
            }
            .controlSize(.small)
        case .denied, .restricted:
            Button("Open Settings") { openMicrophoneSettings() }
                .controlSize(.small)
        case .authorized:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Sub-divisions inside the Models pane. The Models tab was getting hard to
/// scan once the live memory readout, two transcription engines, the LLM
/// list, and the Finder shortcut all shared a single scrolling Form — so
/// they live behind a segmented picker at the top.
private enum ModelsSubPane: String, CaseIterable, Identifiable {
    case transcription = "Transcription"
    case formatting = "Formatting"
    case stats = "Stats"
    var id: String { rawValue }
}

/// Full-width footnote / description Text for use inside Form sections
/// (`Section { … }` content or its `footer:` slot) on macOS. macOS's grouped
/// Form lays each row out as label + content columns; a bare Text gets
/// allocated only the trailing column and wraps at roughly half the section
/// width. Wrapping it in an HStack with a trailing Spacer claims the full row
/// width so multi-line copy flows to the section's actual edge.
private struct SectionFootnote: View {
    private let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct ModelsPane: View {
    @State private var manager = ModelManager.shared
    /// Which sub-pane is showing. Reset to Transcription on each entry to
    /// the Models tab — that's the most common reason to come here, and
    /// landing on Stats first would bury the actual model lists.
    @State private var subPane: ModelsSubPane = .transcription

    var body: some View {
        VStack(spacing: 0) {
            Picker("Models section", selection: $subPane) {
                ForEach(ModelsSubPane.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            switch subPane {
            case .transcription: TranscriptionModelsPane()
            case .formatting: FormattingModelsPane()
            case .stats: StatsModelsPane()
            }
        }
        // Refresh on-disk download state when the user opens the Models
        // tab. Each sub-pane reads from the same shared ModelManager so a
        // single refresh covers all three.
        .onAppear { manager.refreshCachedStates() }
    }
}

/// Transcription sub-pane: engine picker, Parakeet variant list, Whisper
/// variant list. The engine picker lives at the top because flipping
/// engines is more frequent than picking a different variant within an
/// engine. Parakeet is presented first — it's the faster, lighter default
/// recommendation for almost everyone.
private struct TranscriptionModelsPane: View {
    @Environment(AppState.self) private var state
    @State private var manager = ModelManager.shared
    @State private var transcription = TranscriptionServiceHolder.shared
    @State private var parakeet = ParakeetServiceHolder.shared
    /// Set when the user tries to switch to an engine that has no installed
    /// models. We refuse the switch (keeps `settings.transcriptionEngine`
    /// pointing at a usable engine) and pop an alert directing them to the
    /// matching section's Download button.
    @State private var engineSwitchBlocked: TranscriptionEngine? = nil

    private func hasReadyModel(in engine: TranscriptionEngine) -> Bool {
        switch engine {
        case .whisper:
            return ModelCatalog.whisperModels.contains { manager.whisperStates[$0.id] == .ready }
        case .parakeet:
            return ModelCatalog.parakeetModels.contains { manager.parakeetStates[$0.id] == .ready }
        }
    }

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Picker("Engine", selection: Binding(
                    get: { s.settings.transcriptionEngine },
                    set: { newValue in
                        // Refuse the switch when no model is downloaded in
                        // the target engine — otherwise the next dictation
                        // would silently auto-download a multi-GB model.
                        guard hasReadyModel(in: newValue) else {
                            engineSwitchBlocked = newValue
                            return
                        }
                        s.settings.transcriptionEngine = newValue
                        state.save()
                    }
                )) {
                    Text("Parakeet (FluidAudio)").tag(TranscriptionEngine.parakeet)
                    Text("Whisper (WhisperKit)").tag(TranscriptionEngine.whisper)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Transcription engine")
            } footer: {
                SectionFootnote("**Parakeet** uses the Apple Neural Engine — roughly an order of magnitude faster than Whisper on Apple Silicon, and slightly smaller on disk. v3 covers 25 European languages; v2 is English-only with marginally better English accuracy. **Whisper** is the mature alternative — slower, but broad language support and very well-tested.")
            }
            .alert(
                "No \(engineSwitchBlocked == .parakeet ? "Parakeet" : "Whisper") models installed",
                isPresented: Binding(
                    get: { engineSwitchBlocked != nil },
                    set: { if !$0 { engineSwitchBlocked = nil } }
                ),
                presenting: engineSwitchBlocked
            ) { _ in
                Button("OK", role: .cancel) { engineSwitchBlocked = nil }
            } message: { engine in
                Text("Download a \(engine == .parakeet ? "Parakeet" : "Whisper") model from the section below before switching engines.")
            }

            Section {
                ForEach(ModelCatalog.parakeetModels) { model in
                    ModelRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        ramMB: model.approxRAMMB,
                        state: manager.parakeetStates[model.id] ?? .unknown,
                        isActive: s.settings.transcriptionEngine == .parakeet && s.settings.parakeetModelID == model.id,
                        isLoaded: parakeet.currentModelID == model.id,
                        isVerifying: manager.verifyingParakeet.contains(model.id),
                        select: {
                            s.settings.parakeetModelID = model.id
                            s.settings.transcriptionEngine = .parakeet
                            state.save()
                        },
                        download: {
                            manager.downloadParakeet(model.id, using: ParakeetServiceHolder.shared)
                        },
                        cancel: {
                            manager.cancelParakeetDownload(model.id)
                        },
                        verify: {
                            Task { await manager.verifyParakeet(model.id, using: ParakeetServiceHolder.shared) }
                        },
                        unload: {
                            manager.unloadParakeet(model.id, using: ParakeetServiceHolder.shared)
                        },
                        remove: {
                            manager.removeParakeet(model.id, using: ParakeetServiceHolder.shared)
                        }
                    )
                }
            } header: {
                Text("Parakeet models")
            } footer: {
                SectionFootnote("Parakeet runs on the Apple Neural Engine — much faster than Whisper. **v3** covers 25 European languages; **v2** is English-only and slightly more accurate on English. Resumable downloads aren't supported (a cancelled download is discarded and re-fetched fresh next time).")
            }

            Section {
                ForEach(ModelCatalog.whisperModels) { model in
                    ModelRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        ramMB: model.approxRAMMB,
                        state: manager.whisperStates[model.id] ?? .unknown,
                        isActive: s.settings.transcriptionEngine == .whisper && s.settings.whisperModelID == model.id,
                        isLoaded: transcription.currentModelID == model.id,
                        isVerifying: manager.verifyingWhisper.contains(model.id),
                        select: {
                            s.settings.whisperModelID = model.id
                            s.settings.transcriptionEngine = .whisper
                            state.save()
                        },
                        download: {
                            manager.downloadWhisper(model.id, using: TranscriptionServiceHolder.shared)
                        },
                        cancel: {
                            manager.cancelWhisperDownload(model.id)
                        },
                        verify: {
                            Task { await manager.verifyWhisper(model.id, using: TranscriptionServiceHolder.shared) }
                        },
                        unload: {
                            manager.unloadWhisper(model.id, using: TranscriptionServiceHolder.shared)
                        },
                        remove: {
                            manager.removeWhisper(model.id, using: TranscriptionServiceHolder.shared)
                        }
                    )
                }
            } header: {
                Text("Whisper models")
            } footer: {
                SectionFootnote("Pick the model that runs when you dictate with Whisper. Larger models are more accurate but slower and use more memory. A model downloads automatically the first time you use it; you can also download ahead of time below. **Verify** loads the model into memory to confirm the download finished cleanly — useful after a flaky connection.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Formatting sub-pane: the LLM picker plus a None option that disables
/// every LLM pass in the pipeline. Lives in its own sub-tab because
/// "which speech-to-text" and "which LLM tidies the result" are two
/// independent choices.
private struct FormattingModelsPane: View {
    @Environment(AppState.self) private var state
    @State private var manager = ModelManager.shared
    @State private var llm = LLMServiceHolder.shared

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                NoneLLMRow(
                    isActive: s.settings.llmModelID == ModelCatalog.noneLLMID,
                    select: {
                        s.settings.llmModelID = ModelCatalog.noneLLMID
                        state.save()
                    }
                )
                ForEach(ModelCatalog.llmModels) { model in
                    ModelRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        ramMB: model.approxRAMMB,
                        state: manager.llmStates[model.id] ?? .unknown,
                        isActive: s.settings.llmModelID == model.id,
                        isLoaded: llm.currentModelID == model.id,
                        isVerifying: manager.verifyingLLM.contains(model.id),
                        select: {
                            s.settings.llmModelID = model.id
                            state.save()
                        },
                        download: {
                            manager.downloadLLM(model.id, using: LLMServiceHolder.shared)
                        },
                        cancel: {
                            manager.cancelLLMDownload(model.id)
                        },
                        verify: {
                            Task { await manager.verifyLLM(model.id, using: LLMServiceHolder.shared) }
                        },
                        unload: {
                            manager.unloadLLM(model.id, using: LLMServiceHolder.shared)
                        },
                        remove: {
                            manager.removeLLM(model.id, using: LLMServiceHolder.shared)
                        }
                    )
                }
            } header: {
                Text("Formatting LLM (MLX)")
            } footer: {
                SectionFootnote("Used for the formatting, grammar, and structural passes after transcription — and for Assistant Mode. Pick **None** to skip LLM passes and ship the raw transcript.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Stats sub-pane: live memory readout (physical RAM, current RSS, sum of
/// the selected combo's approx RAM cost), plus a shortcut to reveal the
/// on-disk model cache in Finder. Diagnostic-flavoured information that
/// would otherwise compete for attention with the model lists.
private struct StatsModelsPane: View {
    @Environment(AppState.self) private var state
    /// Live memory reading, refreshed every 2 s while this sub-pane is on
    /// screen via a `.task` poll loop. Zero until the first read lands.
    @State private var memory: MemoryReading = .zero
    /// MLX GPU buffer accounting. `activeMemory` is what current inference
    /// arrays hold; `cacheMemory` is the recycle pool (capped to 512 MB at
    /// launch — see `AppState.bootstrap()`); `peakMemory` is the high-
    /// water mark since process start. Zero until the first MLX call.
    @State private var mlxSnapshot: GPU.Snapshot?

    /// Sum of the approximate RAM costs for the *currently selected* models —
    /// the active transcription engine's chosen variant plus the chosen LLM
    /// (skipped when LLM is set to None). Forward-looking — answers "what
    /// would Dictator use if all selected models were resident?" rather than
    /// "what is it using now."
    private func selectedComboRAMMB(_ settings: DictatorSettings) -> Int {
        var total = 0
        switch settings.transcriptionEngine {
        case .whisper:
            total += ModelCatalog.whisper(id: settings.whisperModelID)?.approxRAMMB ?? 0
        case .parakeet:
            total += ModelCatalog.parakeet(id: settings.parakeetModelID)?.approxRAMMB ?? 0
        }
        if settings.llmModelID != ModelCatalog.noneLLMID {
            total += ModelCatalog.llm(id: settings.llmModelID)?.approxRAMMB ?? 0
        }
        return total
    }

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                LabeledContent("This Mac") {
                    Text(memory.physicalDisplay)
                        .monospacedDigit()
                }
                LabeledContent("Dictator using") {
                    Text(memory.residentDisplay)
                        .monospacedDigit()
                }
                LabeledContent("Selected models, loaded") {
                    Text("≈\(formatModelSize(selectedComboRAMMB(s.settings)))")
                        .monospacedDigit()
                }
            } header: {
                Text("Memory")
            } footer: {
                SectionFootnote("Live readout. \"Dictator using\" mirrors Activity Monitor's footprint (which counts compressed and GPU-mapped pages); the actual physical RAM cost is often less because macOS compresses cold pages.")
            }

            Section {
                LabeledContent("Active") {
                    Text(Self.formatBytes(mlxSnapshot?.activeMemory ?? 0))
                        .monospacedDigit()
                }
                LabeledContent("Cache") {
                    Text(Self.formatBytes(mlxSnapshot?.cacheMemory ?? 0))
                        .monospacedDigit()
                }
                LabeledContent("Peak since launch") {
                    Text(Self.formatBytes(mlxSnapshot?.peakMemory ?? 0))
                        .monospacedDigit()
                }
            } header: {
                Text("MLX (LLM)")
            } footer: {
                SectionFootnote("Active: buffers held by current inference. Cache: recyclable buffer pool, capped at 512 MB. Peak: highest active since launch. All three are GPU-mapped pages that count against Dictator's footprint.")
            }

            Section {
                Button("Reveal Models in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.root()])
                }
            } header: {
                Text("On disk")
            } footer: {
                SectionFootnote("All downloaded model files live under `~/Library/Application Support/Dictator/Models/`.")
            }
        }
        .formStyle(.grouped)
        // Refresh the live memory section on a 2 s cadence while the Stats
        // sub-pane is on screen. `.task` is automatically cancelled when
        // the user switches sub-pane or tab. The first read fires
        // immediately so the section never renders with the .zero
        // placeholder.
        .task {
            while !Task.isCancelled {
                memory = MemoryReporter.read()
                mlxSnapshot = MLX.GPU.snapshot()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Binary-prefix byte formatter that matches the Activity-Monitor /
    /// "About This Mac" convention (1 GB == 2³⁰ bytes). Falls through to
    /// MB / KB for sub-GB values so the MLX rows read cleanly even when
    /// the LLM hasn't allocated much yet.
    private static func formatBytes(_ bytes: Int) -> String {
        let value = Double(bytes)
        let gib = value / 1_073_741_824
        if gib >= 1 {
            return String(format: "%.1f GB", gib)
        }
        let mib = value / 1_048_576
        if mib >= 1 {
            return String(format: "%.0f MB", mib)
        }
        let kib = value / 1_024
        return String(format: "%.0f KB", kib)
    }
}

fileprivate func formatModelSize(_ mb: Int) -> String {
    if mb >= 1000 {
        return String(format: "%.1f GB", Double(mb) / 1000.0)
    }
    return "\(mb) MB"
}

/// One row per model in the catalog. Left side: radio + name + size + note +
/// per-state inline status. Right side: state-dependent action (Download /
/// Cancel / Remove). The whole row's leading area is tappable to set this
/// model as the active choice.
private struct ModelRow: View {
    let name: String
    let note: String
    let sizeMB: Int
    /// Approximate steady-state RAM cost when this model is loaded. Surfaced
    /// in the caption next to disk size so a user picking between models can
    /// see the memory trade-off without leaving the pane.
    let ramMB: Int
    let state: ModelDownloadState
    let isActive: Bool
    let isLoaded: Bool
    let isVerifying: Bool
    let select: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let verify: () -> Void
    let unload: () -> Void
    let remove: () -> Void

    @State private var confirmingRemoval = false

    /// Only `.ready` rows can be made active — clicking a not-yet-downloaded
    /// row used to silently kick off a multi-GB download on the next hotkey
    /// press, which is a terrible "what just happened" moment. Force the user
    /// through Download → wait → become active so the cost is explicit.
    private var canSelect: Bool {
        if case .ready = state { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: select) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name).fontWeight(isActive ? .semibold : .regular)
                            if isActive {
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor, in: Capsule())
                            }
                            if isLoaded {
                                Text("Loaded")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.green, in: Capsule())
                            }
                            FitChip(ramMB: ramMB)
                        }
                        Text("\(note) · \(formatModelSize(sizeMB)) disk · ≈\(formatModelSize(ramMB)) RAM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .opacity(canSelect ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .help(canSelect ? "" : "Download this model to make it active.")

            actionView
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove \(name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the model files from disk (~\(formatModelSize(sizeMB))). You can re-download it any time.")
        }
    }

    @ViewBuilder private var actionView: some View {
        switch state {
        case .ready:
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                if isVerifying {
                    ProgressView().controlSize(.mini)
                } else if isLoaded {
                    Button("Unload", action: unload)
                        .controlSize(.small)
                        .help("Drop this model from memory (files stay on disk)")
                } else {
                    Button("Verify", action: verify)
                        .controlSize(.small)
                        .help("Load into memory to confirm the download is intact")
                }
                TrashTapGlyph(action: { confirmingRemoval = true }, tooltip: "Remove this model from disk")
            }
            .font(.callout)
        case .notDownloaded, .unknown:
            Button("Download", action: download)
                .controlSize(.small)
        case .preparingDownload:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Fetching metadata…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
        case .partial(let p):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: p)
                        .frame(width: 110)
                        .tint(.orange)
                    Text("Paused · \(Int(p * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Resume", action: download)
                    .controlSize(.small)
                    .help("Continue downloading from where it stopped")
                TrashTapGlyph(action: { confirmingRemoval = true }, tooltip: "Discard partial download")
                    .font(.callout)
            }
        case .downloading(let p):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: p)
                        .frame(width: 110)
                    Text("\(Int(p * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            }
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Failed").foregroundStyle(.red).font(.caption)
                    Button("Retry", action: download)
                        .controlSize(.small)
                    TrashTapGlyph(action: { confirmingRemoval = true }, tooltip: "Remove any partial files from disk")
                        .font(.callout)
                }
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// Special "None" pseudo-model for the LLM section — selectable but has no
/// download/remove affordances since there's nothing to download.
private struct NoneLLMRow: View {
    let isActive: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("None").fontWeight(isActive ? .semibold : .regular)
                        if isActive {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                    Text("Ship Whisper's raw transcript — no formatting, grammar, structural, or assistant passes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

/// Trash icon rendered as a *text glyph* (`Text(Image(...))`) rather than a
/// standalone `Image`. Text-glyph SF Symbols inherit the surrounding text's
/// baseline metrics, so when this sits next to a `Label("…", systemImage: …)`
/// the trash lines up with the label's icon and text on the same baseline —
/// which standalone `Image` views can't guarantee because they use image
/// metrics with per-glyph bounding boxes that differ between symbols.
private struct TrashTapGlyph: View {
    let action: () -> Void
    let tooltip: String
    @State private var hovering = false

    var body: some View {
        Text(Image(systemName: "trash"))
            .foregroundStyle(hovering ? Color.red.opacity(0.85) : .secondary)
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .onHover { hovering in
                self.hovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help(tooltip)
    }
}

private struct PromptPane: View {
    @Environment(AppState.self) private var state
    @State private var selected: Tab = .formatting

    enum Tab: String, CaseIterable, Identifiable {
        case formatting = "Pass 1 · Formatting"
        case grammar    = "Pass 2 · Grammar"
        case structure  = "Pass 3 · Structure"
        case assistant  = "Assistant Mode"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selected) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch selected {
            case .formatting:
                PromptCustomiser(
                    description: "Punctuation, emojis, capitalisation. Runs on every dictation.",
                    builtin: DictatorSettings.builtinFormattingPrompt,
                    addendum: $s.settings.formattingPromptAddendum,
                    override: $s.settings.formattingPromptOverride
                ) { state.save() }
            case .grammar:
                PromptCustomiser(
                    description: "Fixes obvious grammar errors after pass 1. Runs only when **Tidy grammar** is enabled. Result is discarded if too many words change.",
                    builtin: DictatorSettings.builtinGrammarPrompt,
                    addendum: $s.settings.grammarPromptAddendum,
                    override: $s.settings.grammarPromptOverride
                ) { state.save() }
            case .structure:
                PromptCustomiser(
                    description: "Adds paragraph breaks and bullet lists. Runs only when **Restructure long dictations** is enabled and the transcript is long enough. Word changes are rejected automatically.",
                    builtin: DictatorSettings.builtinStructuralPrompt,
                    addendum: $s.settings.structuralPromptAddendum,
                    override: $s.settings.structuralPromptOverride
                ) { state.save() }
            case .assistant:
                PromptCustomiser(
                    description: "Used when you trigger the Assistant hotkey. The model classifies its own reply as REPLACE (paste at the cursor) or DRAFT (clipboard only).",
                    builtin: DictatorSettings.builtinAssistantPrompt,
                    addendum: $s.settings.assistantPromptAddendum,
                    override: $s.settings.assistantPromptOverride
                ) { state.save() }
            }
        }
    }
}

/// Per-prompt editor. Two modes:
/// - Addendum mode (default): edit a small "Additional instructions" field that
///   gets appended under the built-in at send time.
/// - Override mode: the built-in is replaced entirely with the user's text. A
///   prominent warning explains the risks; a toggle at the bottom flips between
///   modes. The built-in itself lives behind a "View built-in prompt" button
///   that opens a sheet (it's reference material, not edit surface).
private struct PromptCustomiser: View {
    let description: String
    let builtin: String
    @Binding var addendum: String
    @Binding var override: String?
    let onChange: () -> Void

    @State private var showBuiltinSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(.init(description))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if override == nil {
                    addendumEditor
                } else {
                    overrideEditor
                }

                Divider()

                HStack(spacing: 16) {
                    Toggle(isOn: Binding(
                        get: { override != nil },
                        set: { isOn in
                            // Seed override with the current built-in on toggle-on, so the
                            // user has something to modify rather than a blank canvas. On
                            // toggle-off we discard the override entirely — the addendum
                            // takes back over.
                            override = isOn ? builtin : nil
                            onChange()
                        }
                    )) {
                        Text("Replace built-in prompt entirely")
                            .font(.subheadline)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Spacer()
                    Button {
                        showBuiltinSheet = true
                    } label: {
                        Label("View built-in prompt", systemImage: "doc.text")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showBuiltinSheet) {
            BuiltinPromptSheet(prompt: builtin, isPresented: $showBuiltinSheet)
        }
    }

    private var addendumEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional instructions (optional)")
                .font(.subheadline.weight(.medium))
            Text("Appended under the built-in prompt. Use for small personal tweaks — e.g. \"always use British spelling\" or \"never include em-dashes\".")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $addendum)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .frame(height: 220)
                .onChange(of: addendum) { _, _ in onChange() }
            if !addendum.isEmpty {
                HStack {
                    Button("Clear") {
                        addendum = ""
                        onChange()
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private var overrideEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Substantive warning: not just "this won't update", but explicit about the
            // failure modes the built-in is engineered to prevent.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Custom override active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Text("The built-in prompt contains carefully-tuned rules that prevent common model failures — answering questions instead of transcribing them, leaking conversational preambles, output drifting away from your input. If your custom prompt is missing those rules, you may get **incorrect or unexpected responses**.")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Text("Future updates to the built-in are often pushed to fix newly-discovered failures. Those won't apply while this override is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))

            Text("Custom prompt (replaces built-in)")
                .font(.subheadline.weight(.medium))
            TextEditor(text: Binding(
                get: { override ?? "" },
                set: { newValue in
                    override = newValue
                    onChange()
                }
            ))
            .font(.system(size: 12, design: .monospaced))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4)))
            .frame(height: 360)
        }
    }
}

private struct BuiltinPromptSheet: View {
    let prompt: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Built-in prompt")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                Text(prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 720, height: 520)
    }
}
