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
    /// Live entry count for the "Vocabulary" row's trailing subtitle.
    /// Read directly off the shared store so a row added on another
    /// device (via the shared folder) updates the row without any
    /// extra plumbing here.
    @Bindable var store: VocabularyStore = .shared
    /// Drives the same `KeyboardSetupSheet` the onboarding card on
    /// the main view uses, but reachable from Settings so the user
    /// can find the walkthrough again after dismissing the card.
    @State private var showingKeyboardSetup = false
    @State private var showingFolderPicker = false
    /// Full path of the configured shared folder, as a `›`-separated
    /// breadcrumb (`iCloud Drive › Documents › Dictator`). Recomputed
    /// on appear and after a successful pick / disconnect so the UI
    /// doesn't have to introspect `SharedFolderBookmark` on every
    /// SwiftUI render. `nil` means the user hasn't opted in.
    @State private var sharedFolderPath: String?
    /// Last shared-folder error (stale bookmark, permission denied,
    /// etc.). Shown inline so the user sees why it didn't connect.
    @State private var sharedFolderError: String?

    @AppStorage(DictatorIOSSettings.foundationCleanupKey) private var foundationCleanupEnabled = false

    /// Snapshotted once on view appear — `SystemLanguageModel.default.availability`
    /// doesn't change during a session except via going to Settings to
    /// flip Apple Intelligence on/off, which would deactivate the app
    /// and re-render the view on return anyway.
    @State private var foundationAvailable: Bool = AppleFoundationCleanup.isAvailable
    /// Structured availability for the Assist feature, used to render
    /// an explanation row that tells the user why the purple button
    /// isn't there — distinguishes "your phone can't run this" from
    /// "you just need to turn Apple Intelligence on" so the copy
    /// matches what the user can do about it.
    @State private var assistAvailability: AppleFoundationAssist.Availability = AppleFoundationAssist.availability

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
            } else if let explanation = assistAvailability.explanation {
                // Mirror-image of the section above: when the foundation
                // model isn't reachable we tell the user why, so they're
                // not left wondering where Assist went. Copy differs per
                // reason — see `AppleFoundationAssist.Availability` —
                // because "buy a new phone" and "flip a switch" are very
                // different asks. No deep link: iOS doesn't expose a
                // public URL for the Apple Intelligence settings page,
                // and Apple has clamped down on the `App-prefs:` shim.
                Section {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(assistAvailability.sectionTitle)
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
                if let sharedFolderPath {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.icloud.fill")
                                .foregroundStyle(.green)
                            Text(sharedFolderPath)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
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
                    SubstitutionsView()
                } label: {
                    Label("Substitutions", systemImage: "arrow.left.arrow.right")
                }
                NavigationLink {
                    VocabularyView()
                } label: {
                    Label {
                        HStack {
                            Text("Vocabulary")
                            Spacer()
                            Text("\(store.entries.count)")
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "character.book.closed")
                    }
                }
                NavigationLink {
                    StatsView()
                } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
                NavigationLink {
                    AboutView()
                } label: {
                    Label("About Dictator", systemImage: "info.circle")
                }
            }

            #if DEBUG
            debugSection
            #endif
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshSharedFolderState()
            // Re-query so the explanation section updates if the user
            // flipped Apple Intelligence in iOS Settings since launch.
            foundationAvailable = AppleFoundationCleanup.isAvailable
            assistAvailability = AppleFoundationAssist.availability
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderPick(result)
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
        sharedFolderPath = SharedFolderBookmark.displayPath
        sharedFolderError = nil
    }

    // MARK: - Debug

    #if DEBUG
    /// Developer-only Settings section that forces a fake
    /// `SystemLanguageModel` availability state across the host app
    /// AND the keyboard extension (the value is persisted to the App
    /// Group so both processes pick it up). The simulator inherits
    /// the host Mac's Apple Intelligence support, so simulating an
    /// older-iPhone ".deviceNotEligible" path can't be done any
    /// other way without flying a real device. Stripped from
    /// release builds entirely.
    @ViewBuilder
    private var debugSection: some View {
        Section {
            Picker("Force Assist state", selection: forcedAssistBinding) {
                Text("Real (from OS)").tag(Optional<KeyboardBridge.DebugAssistAvailability>.none)
                Text("Available").tag(Optional(KeyboardBridge.DebugAssistAvailability.available))
                Text("Not enabled").tag(Optional(KeyboardBridge.DebugAssistAvailability.notEnabled))
                Text("Device not eligible").tag(Optional(KeyboardBridge.DebugAssistAvailability.deviceNotEligible))
                Text("Model not ready").tag(Optional(KeyboardBridge.DebugAssistAvailability.modelNotReady))
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Lets you force the Apple Intelligence availability path the rest of the app reads. Keyboard picks it up within ~300 ms. Debug-only — not in the release build.")
        }
    }

    /// Two-way binding to the App Group-persisted override, plus a
    /// local state refresh so the explanation section above re-renders
    /// the moment the picker changes (without it the picker flips but
    /// the rest of the Settings list stays stale until the next appear).
    private var forcedAssistBinding: Binding<KeyboardBridge.DebugAssistAvailability?> {
        Binding(
            get: { KeyboardBridge.debugForcedAssistAvailability },
            set: { newValue in
                KeyboardBridge.setDebugForcedAssistAvailability(newValue)
                assistAvailability = AppleFoundationAssist.availability
                foundationAvailable = AppleFoundationCleanup.isAvailable
            }
        )
    }
    #endif

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
