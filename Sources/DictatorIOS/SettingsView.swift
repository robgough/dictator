import SwiftUI
import UniformTypeIdentifiers

/// Settings — currently just the vocabulary editor. The macOS app has a
/// much richer Settings surface (modes, prompts, LLM model picker,
/// hotkeys, paste/sounds) but most of those don't apply to the iOS
/// prototype: there's no global hotkey, no host-app paste, no LLM
/// passes yet. The deterministic post-transcription substitution is
/// the one knob the prototype actually exposes today.
struct SettingsView: View {
    @Bindable var viewModel: RecordingViewModel
    @Bindable var store: VocabularyStore = .shared
    @State private var editingEntry: VocabularyEntry?
    @State private var showingNewSheet = false
    /// Drives the same `KeyboardSetupSheet` the onboarding card on
    /// the main view uses, but reachable from Settings so the user
    /// can find the walkthrough again after dismissing the card.
    @State private var showingKeyboardSetup = false
    @State private var showingFolderPicker = false
    /// Folder name surfaced under the "Shared folder" row. Recomputed
    /// on appear and after a successful pick / disconnect so the UI
    /// doesn't have to introspect `SharedFolderBookmark` on every
    /// SwiftUI render. `nil` means the user hasn't opted in.
    @State private var sharedFolderName: String?
    /// Last shared-folder error (stale bookmark, permission denied,
    /// etc.). Shown inline so the user sees why it didn't connect.
    @State private var sharedFolderError: String?

    @AppStorage(DictatorIOSSettings.cuePunctuationKey) private var punctuationEnabled = true
    @AppStorage(DictatorIOSSettings.cueNumbersKey) private var numbersEnabled = true
    @AppStorage(DictatorIOSSettings.cueTimesKey) private var timesEnabled = true
    @AppStorage(DictatorIOSSettings.cueCurrencyKey) private var currencyEnabled = true
    @AppStorage(DictatorIOSSettings.cueEmojisKey) private var emojisEnabled = true
    @AppStorage(DictatorIOSSettings.foundationCleanupKey) private var foundationCleanupEnabled = false

    /// Snapshotted once on view appear — `SystemLanguageModel.default.availability`
    /// doesn't change during a session except via going to Settings to
    /// flip Apple Intelligence on/off, which would deactivate the app
    /// and re-render the view on return anyway.
    @State private var foundationAvailable: Bool = AppleFoundationCleanup.isAvailable

    var body: some View {
        List {
            Section {
                Button {
                    showingKeyboardSetup = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set up the Dictator keyboard")
                                .foregroundStyle(.primary)
                            Text("Voice typing in any app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "keyboard.fill")
                            .foregroundStyle(.purple)
                    }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Walks you through enabling the Dictator keyboard in iOS Settings, with one-tap deep-link to the right page.")
            }

            if foundationAvailable {
                Section {
                    Toggle("Tidy filler words", isOn: $foundationCleanupEnabled)
                } header: {
                    Text("Apple Intelligence")
                } footer: {
                    Text("Runs Apple's on-device foundation model after transcription to drop \"um\", \"uh\", repeated stutters, and false-starts. Strict content-preservation check reverts to the raw transcript if the model paraphrases.")
                }
            }

            Section {
                Picker(
                    "Model",
                    selection: Binding(
                        get: { viewModel.selectedModelID },
                        set: { viewModel.selectModel($0) }
                    )
                ) {
                    Text("v3 · Multilingual").tag("parakeet-tdt-0.6b-v3")
                    Text("v2 · English").tag("parakeet-tdt-0.6b-v2")
                }
            } header: {
                Text("Transcription Model")
            } footer: {
                // Spell out the actual tradeoff. Both models are the same
                // size (~600M params, ~460 MB download); v3 trades a small
                // amount of English accuracy for coverage of ~25 European
                // languages. v2 is the better pick if you only ever dictate
                // in English.
                Text("""
                v3 · Multilingual — Transcribes English, German, French, Italian, Spanish, Portuguese, Russian, Ukrainian, and other European languages.
                v2 · English — English-only; tighter English accuracy than v3 because it isn't splitting capacity across other languages.

                Switching triggers a one-time download if the selected model isn't already on this device. The previous one is unloaded from memory but stays on disk for quick switching back.
                """)
            }

            Section {
                Toggle("Punctuation cues", isOn: $punctuationEnabled)
                Toggle("Numbers & arithmetic", isOn: $numbersEnabled)
                Toggle("Clock times", isOn: $timesEnabled)
                Toggle("Currency", isOn: $currencyEnabled)
                Toggle("Emoji names", isOn: $emojisEnabled)
            } header: {
                Text("Deterministic Substitutions")
            } footer: {
                Text("Punctuation: \"comma\", \"new paragraph\", \"open quote\", \"em dash\", etc.\nNumbers: \"five plus three\" → \"5 + 3\", \"twenty-five\" → 25.\nTimes: \"ten thirty PM\" → \"10:30pm\", \"sixteen hundred hours\" → \"1600 hours\".\nCurrency: \"five dollars\" → \"$5\", \"twenty pounds\" → \"£20\".\nEmoji: \"fire emoji\" → 🔥, \"vulcan emoji\" → 🖖. Covers the full Unicode emoji set by name plus hundreds of curated aliases.")
            }

            Section {
                if store.entries.isEmpty {
                    Text("No replacements yet. Tap + to add one — for example, replace \"laughing emoji\" with 😂, or your codename with the real spelling.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.entries) { entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            VocabularyEntryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            store.entries.remove(at: index)
                        }
                    }
                }
            } header: {
                Text("Word & Emoji Replacements")
            } footer: {
                Text("Applied after transcription, in order. Matches whole words by default (case-insensitive). Tap a row to change those options.")
            }

            Section {
                if let sharedFolderName {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.icloud.fill")
                                .foregroundStyle(.green)
                            Text(sharedFolderName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        Button("Stop using shared folder", role: .destructive) {
                            disconnectSharedFolder()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use a shared folder")
                                    .foregroundStyle(.primary)
                                Text("Sync vocabulary and usage stats with your Mac")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "icloud.and.arrow.up")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                if let sharedFolderError {
                    Text(sharedFolderError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Shared folder")
            } footer: {
                Text("Pick a folder in iCloud Drive — typically iCloud Drive › Documents › Dictator on a Mac with Desktop & Documents syncing turned on — to share your custom vocabulary and your usage counters with the Mac app or another iPhone signed in to the same iCloud account. Dictation history and assistant conversations stay on this device only.")
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About Dictator", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .onAppear { refreshSharedFolderState() }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderPick(result)
        }
        .sheet(isPresented: $showingNewSheet) {
            VocabularyEntryEditor(entry: nil) { newEntry in
                store.entries.append(newEntry)
            }
        }
        .sheet(item: $editingEntry) { entry in
            VocabularyEntryEditor(entry: entry) { updated in
                if let index = store.entries.firstIndex(where: { $0.id == updated.id }) {
                    store.entries[index] = updated
                }
            }
        }
        .sheet(isPresented: $showingKeyboardSetup) {
            KeyboardSetupSheet()
        }
    }

    /// Re-reads the bookmark on view appear so the row reflects state
    /// changes made elsewhere (e.g. iOS revoked the grant because the
    /// folder was deleted). `SharedFolderBookmark.activeURL` is set on
    /// app launch by `DictatorIOSApp.init`; this just surfaces it.
    private func refreshSharedFolderState() {
        sharedFolderName = SharedFolderBookmark.displayName
        sharedFolderError = nil
    }

    /// Handles the `.fileImporter` callback. On success: save the
    /// bookmark, point the two opt-in stores at the new folder, and
    /// refresh the UI. On failure: surface the error inline so the
    /// user knows why it didn't take.
    private func handleFolderPick(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            sharedFolderError = "Couldn't read the chosen folder: \(error.localizedDescription)"
        case .success(let urls):
            guard let picked = urls.first else { return }
            do {
                let resolved = try SharedFolderBookmark.save(picked)
                // Re-bootstrap both opt-in stores against the new
                // location. Vocab union-merges this device's existing
                // entries with whatever the shared folder already had;
                // stats merges by per-device record so other Macs'
                // counters are preserved alongside this device's.
                let existingEntries = VocabularyStore.shared.entries
                VocabularyStore.shared.bootstrap(customDirectory: resolved, legacyEntries: existingEntries)
                UsageStatsStore.shared.bootstrap(customDirectory: resolved)
                sharedFolderError = nil
                refreshSharedFolderState()
            } catch {
                sharedFolderError = "Couldn't connect to the folder: \(error.localizedDescription)"
            }
        }
    }

    /// Drops the bookmark and re-points both stores at their sandbox
    /// defaults. This device's vocab + stats stay populated in memory;
    /// the next write lands in the sandbox so the local snapshot is
    /// preserved without further user action.
    private func disconnectSharedFolder() {
        SharedFolderBookmark.clear()
        let existingEntries = VocabularyStore.shared.entries
        VocabularyStore.shared.bootstrap(customDirectory: nil, legacyEntries: existingEntries)
        UsageStatsStore.shared.bootstrap(customDirectory: nil)
        refreshSharedFolderState()
    }
}

// MARK: - Row

private struct VocabularyEntryRow: View {
    let entry: VocabularyEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.pattern.isEmpty ? "—" : entry.pattern)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(entry.replacement.isEmpty ? "—" : entry.replacement)
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if entry.caseSensitive {
                    Badge(text: "Aa", systemImage: "textformat")
                }
                if entry.wholeWord {
                    Badge(text: "Whole word", systemImage: "text.word.spacing")
                }
            }
        }
        .contentShape(Rectangle())
    }
}

private struct Badge: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color(.tertiarySystemBackground))
        )
        .foregroundStyle(.secondary)
    }
}

// MARK: - Editor

private struct VocabularyEntryEditor: View {
    @Environment(\.dismiss) private var dismiss

    let entry: VocabularyEntry?
    let onSave: (VocabularyEntry) -> Void

    @State private var pattern: String
    @State private var replacement: String
    @State private var caseSensitive: Bool
    @State private var wholeWord: Bool

    init(entry: VocabularyEntry?, onSave: @escaping (VocabularyEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _pattern = State(initialValue: entry?.pattern ?? "")
        _replacement = State(initialValue: entry?.replacement ?? "")
        _caseSensitive = State(initialValue: entry?.caseSensitive ?? false)
        _wholeWord = State(initialValue: entry?.wholeWord ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pattern", text: $pattern, prompt: Text("e.g. laughing emoji"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Replacement", text: $replacement, prompt: Text("e.g. 😂"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Match")
                } footer: {
                    Text("The pattern is matched literally — no regex needed.")
                }

                Section {
                    Toggle("Case sensitive", isOn: $caseSensitive)
                    Toggle("Whole words only", isOn: $wholeWord)
                } footer: {
                    Text("With Whole words off, partial matches inside other words count. With case sensitivity on, \"hello\" won't match \"Hello\".")
                }
            }
            .navigationTitle(entry == nil ? "New Replacement" : "Edit Replacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedPattern.isEmpty else { return }
                        let saved = VocabularyEntry(
                            id: entry?.id ?? UUID(),
                            pattern: trimmedPattern,
                            replacement: replacement,
                            caseSensitive: caseSensitive,
                            wholeWord: wholeWord
                        )
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
