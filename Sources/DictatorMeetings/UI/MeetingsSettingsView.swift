import SwiftUI
import AppKit
import Sparkle

/// The Meetings Settings window.
///
/// A plain SwiftUI `TabView`, unlike Dictator's AppKit-owned split view: this
/// app has five tabs and no sidebar, so none of the macOS 26 `Settings`-scene
/// limitations that forced Dictator's `SettingsShell` bite here.
struct MeetingsSettingsView: View {
    enum Tab: String, Hashable {
        case general, providers, models, meetings, about
    }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            ProvidersTab()
                .tabItem { Label("Providers", systemImage: "sparkles") }
                .tag(Tab.providers)
            ModelsTab()
                .tabItem { Label("Models", systemImage: "shippingbox") }
                .tag(Tab.models)
            MeetingsTab()
                .tabItem { Label("Meetings", systemImage: "person.2.wave.2") }
                .tag(Tab.meetings)
            AboutTab(updater: SparkleUpdater.controller.updater)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        // Fixed size: a Settings scene that resizes per tab jumps around as
        // the user switches, and the tallest tab (Models) sets the floor.
        .frame(width: 660, height: 560)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(MeetingsAppState.self) private var state

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                TextField("Your name", text: Binding(
                    get: { s.settings.userName },
                    set: { s.settings.userName = $0; state.save() }
                ))
                .textFieldStyle(.roundedBorder)
            } header: {
                Text("You")
            } footer: {
                SectionFootnote("Used to tell the model who recorded the meeting, so your own lines are labelled \"Me\" and drafted replies are signed with your name instead of a placeholder.")
            }

            Section {
                TextEditor(text: Binding(
                    get: { s.settings.globalPromptAddendum },
                    set: { s.settings.globalPromptAddendum = $0; state.save() }
                ))
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .frame(height: 120)
            } header: {
                Text("AI instructions")
            } footer: {
                SectionFootnote("Applied to every pass — live notes, the final notes, the coach report and the notes assistant. Use it for cross-cutting preferences like \"always use British spelling\". Per-prompt tweaks live on the Meetings tab.")
            }

            Section {
                Picker("Delete audio after", selection: Binding(
                    get: { s.settings.meetingAudioRetentionDays },
                    set: { s.settings.meetingAudioRetentionDays = $0; state.save() }
                )) {
                    Text("Keep forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.menu)

                Picker("Delete entire meeting after", selection: Binding(
                    get: { s.settings.meetingAutoDeleteAfterDays },
                    set: { s.settings.meetingAutoDeleteAfterDays = $0; state.save() }
                )) {
                    Text("Keep forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.menu)
            } header: {
                ThisMacHeader("Storage")
            } footer: {
                SectionFootnote("Meeting audio is large (~800 MB/hour across both tracks); transcripts are tiny. \"Delete audio\" prunes the .caf files but keeps the transcript, so older meetings stay searchable. \"Delete entire meeting\" drops everything. Both sweeps run when the app opens.")
            }

            Section {
                Toggle("Show a status item in the menu bar", isOn: Binding(
                    get: { s.settings.showMenuBarStatus },
                    set: { s.settings.showMenuBarStatus = $0; state.save() }
                ))
            } header: {
                ThisMacHeader("Menu bar")
            } footer: {
                SectionFootnote("Puts a small item in the menu bar with Record / Stop and a way back to this window — it turns red while a meeting is recording. Takes effect on the next launch.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

private struct ProvidersTab: View {
    @Environment(MeetingsAppState.self) private var state
    @State private var editing: ProviderConfig?
    @State private var testing: Set<String> = []

    private var registry: ProviderRegistry { ProviderRegistry.shared }

    var body: some View {
        @Bindable var s = state
        // Read `generation` so this view re-renders when the registry's
        // non-observable inputs change (Dictator launching or quitting).
        let _ = registry.generation

        Form {
            if let message = registry.requirementMessage {
                Section {
                    NoticeBanner(text: message, tint: .orange, icon: "exclamationmark.triangle.fill")
                }
            } else if let note = registry.qualityNote {
                Section {
                    NoticeBanner(text: note, tint: .yellow, icon: "exclamationmark.triangle")
                }
            }

            Section {
                ForEach(s.settings.providers) { config in
                    ProviderRow(
                        config: config,
                        status: registry.status(for: config.id),
                        isTesting: testing.contains(config.id),
                        edit: { editing = config },
                        test: { runTest(config) },
                        remove: config.kind.isLocal ? nil : { remove(config) }
                    )
                }
            } header: {
                HStack {
                    Text("Providers")
                    Spacer()
                    Menu {
                        Button("OpenAI…") { addCloud(kind: .openAICompatible, preset: .openAI) }
                        Button("OpenRouter…") { addCloud(kind: .openAICompatible, preset: .openRouter) }
                        Button("Other OpenAI-compatible server…") { addCloud(kind: .openAICompatible, preset: .custom) }
                        Button("Anthropic…") { addCloud(kind: .anthropic, preset: nil) }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                SectionFootnote("The three local providers are always here and can't be removed. Cloud providers are yours to add; their API keys are stored in your Keychain, never in the settings file.")
            }

            Section {
                ForEach(ProviderSlot.allCases, id: \.self) { slot in
                    SlotPicker(slot: slot)
                }
            } header: {
                Text("Which provider does what")
            } footer: {
                if registry.usesCloudProvider {
                    SectionFootnote("At least one slot is pointed at a cloud provider, so those meetings' transcripts leave this Mac. Everything else — recording, transcription, speaker separation — stays on-device either way.")
                } else {
                    SectionFootnote("Everything is running locally: no transcript leaves this Mac.")
                }
            }

            Section {
                Toggle("Sync keys with iCloud Keychain", isOn: Binding(
                    get: { s.settings.keychainSyncEnabled },
                    set: { setKeychainSync($0) }
                ))
            } footer: {
                SectionFootnote("Off by default. When on, API keys are stored as iCloud Keychain items so your other Macs pick them up; when off they stay on this Mac only.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { config in
            ProviderEditor(config: config)
        }
    }

    private func addCloud(kind: ProviderConfig.Kind, preset: ProviderConfig.Preset?) {
        let name: String
        switch (kind, preset) {
        case (.anthropic, _):            name = "Anthropic"
        case (_, .openAI?):              name = "OpenAI"
        case (_, .openRouter?):          name = "OpenRouter"
        default:                         name = "Custom server"
        }
        let config = ProviderConfig(
            id: UUID().uuidString,
            kind: kind,
            name: name,
            preset: preset,
            baseURL: preset?.defaultBaseURL,
            modelID: kind == .anthropic ? AnthropicProvider.defaultModelID : preset?.sampleModelID
        )
        state.settings.providers.append(config)
        state.save()
        editing = config
    }

    private func remove(_ config: ProviderConfig) {
        if let account = config.keychainAccount { KeychainStore.delete(account: account) }
        state.settings.providers.removeAll { $0.id == config.id }
        if state.settings.liveProviderID == config.id { state.settings.liveProviderID = nil }
        if state.settings.finalProviderID == config.id { state.settings.finalProviderID = nil }
        state.settings.seedDefaultProvidersIfNeeded(preferredLocalKind: nil)
        state.save()
    }

    private func runTest(_ config: ProviderConfig) {
        testing.insert(config.id)
        Task {
            await ProviderRegistry.shared.test(config)
            testing.remove(config.id)
        }
    }

    /// Flipping the toggle has to *move* the existing items: whether an item
    /// is synchronizable is part of its Keychain identity, so a key written
    /// before the flip is invisible to a query made after it.
    private func setKeychainSync(_ enabled: Bool) {
        let accounts = state.settings.providers.compactMap(\.keychainAccount)
        KeychainStore.migrateSynchronizable(accounts: accounts, to: enabled)
        state.settings.keychainSyncEnabled = enabled
        state.save()
    }
}

private struct SlotPicker: View {
    @Environment(MeetingsAppState.self) private var state
    let slot: ProviderSlot

    var body: some View {
        @Bindable var s = state
        let configured = s.settings.providerConfig(for: slot)
        let resolved = ProviderRegistry.shared.resolvedConfig(for: slot)

        VStack(alignment: .leading, spacing: 4) {
            Picker(slot.title, selection: Binding(
                get: { configured?.id ?? "" },
                set: { newValue in
                    switch slot {
                    case .live:  s.settings.liveProviderID = newValue
                    case .final: s.settings.finalProviderID = newValue
                    }
                    state.save()
                }
            )) {
                ForEach(s.settings.providers) { config in
                    Text(config.name).tag(config.id)
                }
            }
            .pickerStyle(.menu)

            Text(slot.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let configured, let resolved, resolved.id != configured.id {
                Label("Not available right now — using \(resolved.name) instead.", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let line = resolved?.privacyLine {
                Label(line, systemImage: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ProviderRow: View {
    let config: ProviderConfig
    let status: ProviderStatus
    let isTesting: Bool
    let edit: () -> Void
    let test: () -> Void
    /// nil for the three local providers, which can't be removed.
    let remove: (() -> Void)?

    @State private var confirmingRemoval = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: config.kind.iconName)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name).fontWeight(.medium)
                    statusDot
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if isTesting {
                ProgressView().controlSize(.mini)
            } else {
                Button("Test", action: test).controlSize(.small)
            }
            Button("Edit…", action: edit).controlSize(.small)
            if remove != nil {
                Button {
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this provider and its saved key")
            }
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove \(config.name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { remove?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also deletes its API key from your Keychain. Meetings already written are unaffected.")
        }
    }

    private var subtitle: String {
        switch status {
        case .failed(let message):
            return message
        case .ok(let model):
            return "Answered as \(model)"
        case .checking, .unknown:
            break
        }
        var parts: [String] = [config.kind.displayName]
        if let model = config.modelID, !model.isEmpty { parts.append(model) }
        if let host = config.resolvedBaseURL, config.preset == .custom { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusDot: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .checking:
            Circle().fill(Color.secondary).frame(width: 7, height: 7)
        case .ok:
            Circle().fill(Color.green).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Color.red).frame(width: 7, height: 7)
        }
    }
}

/// Add / edit sheet. One form for every kind; irrelevant fields are simply
/// absent rather than disabled.
private struct ProviderEditor: View {
    @Environment(MeetingsAppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let config: ProviderConfig

    @State private var name: String = ""
    @State private var preset: ProviderConfig.Preset = .custom
    @State private var baseURL: String = ""
    @State private var modelID: String = ""
    @State private var apiKey: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(config.kind.displayName, systemImage: config.kind.iconName)
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Section {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, _ in commit() }
                } footer: {
                    SectionFootnote("\(config.kind.blurb)")
                }

                if config.kind == .openAICompatible {
                    Section {
                        Picker("Service", selection: $preset) {
                            ForEach(ProviderConfig.Preset.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .onChange(of: preset) { _, newValue in
                            // Adopting a preset replaces a URL the preset owns;
                            // a hand-typed custom URL is left alone.
                            if let url = newValue.defaultBaseURL { baseURL = url }
                            commit()
                        }
                        TextField("Server URL", text: $baseURL, prompt: Text("https://example.com/v1"))
                            .onChange(of: baseURL) { _, _ in commit() }
                    } footer: {
                        SectionFootnote("The API root, without `/chat/completions` on the end.")
                    }
                }

                if config.kind == .anthropic {
                    Section {
                        TextField("Server URL (optional)", text: $baseURL, prompt: Text(AnthropicProvider.defaultBaseURL))
                            .onChange(of: baseURL) { _, _ in commit() }
                    } footer: {
                        SectionFootnote("Leave blank unless you're going through a proxy that re-hosts Anthropic's Messages API.")
                    }
                }

                if config.kind == .localMLX {
                    Section {
                        Picker("Model", selection: $modelID) {
                            ForEach(ModelCatalog.llmModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .onChange(of: modelID) { _, _ in commit() }
                    } footer: {
                        SectionFootnote("Download models on the Models tab. \(ModelCatalog.meetingsRecommendedLLMName) is what the notes are tuned for.")
                    }
                } else if config.kind != .dictator && config.kind != .apple {
                    Section {
                        TextField("Model id", text: $modelID, prompt: Text(modelPlaceholder))
                            .onChange(of: modelID) { _, _ in commit() }
                    } footer: {
                        SectionFootnote("Exactly as the service names it — a wrong id is the most common cause of a failed test.")
                    }
                }

                if config.kind.needsKey {
                    Section {
                        SecureField("API key", text: $apiKey)
                            .onChange(of: apiKey) { _, newValue in
                                guard loaded, let account = config.keychainAccount else { return }
                                KeychainStore.set(newValue,
                                                  account: account,
                                                  synchronizable: state.settings.keychainSyncEnabled)
                            }
                    } header: {
                        Text("Authentication")
                    } footer: {
                        SectionFootnote("Saved straight to your Keychain as you type. It is never written to the settings file, never logged, and never sent anywhere except this provider.")
                    }
                }

                if let line = config.privacyLine {
                    Section {
                        Label(line, systemImage: "arrow.up.forward.app")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 460)
        .onAppear(perform: load)
    }

    private var modelPlaceholder: String {
        switch config.kind {
        case .anthropic:        return AnthropicProvider.defaultModelID
        case .openAICompatible: return (config.preset ?? .custom).sampleModelID
        default:                return ""
        }
    }

    private func load() {
        name = config.name
        preset = config.preset ?? .custom
        baseURL = config.baseURL ?? ""
        modelID = config.modelID ?? (config.kind == .localMLX ? state.settings.localLLMModelID : "")
        if let account = config.keychainAccount {
            apiKey = KeychainStore.get(account: account) ?? ""
        }
        // Only after the fields are populated, so the initial assignment
        // doesn't count as an edit and re-write the Keychain.
        loaded = true
    }

    private func commit() {
        guard loaded else { return }
        guard let index = state.settings.providers.firstIndex(where: { $0.id == config.id }) else { return }
        state.settings.providers[index].name = name
        if config.kind == .openAICompatible {
            state.settings.providers[index].preset = preset
        }
        state.settings.providers[index].baseURL = baseURL.isEmpty ? nil : baseURL
        state.settings.providers[index].modelID = modelID.isEmpty ? nil : modelID
        if config.kind == .localMLX, !modelID.isEmpty {
            // Keep the per-Mac fallback in step, so a provider entry that
            // arrives from another Mac with an unknown id still resolves.
            state.settings.localLLMModelID = modelID
        }
        state.save()
    }
}

private struct NoticeBanner: View {
    let text: String
    let tint: Color
    let icon: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Models

/// Trimmed copy of Dictator's Models pane: the three model families Meetings
/// actually uses (speech, speaker separation, and a local note-writing model).
/// Deliberately a copy rather than a shared view — Dictator's pane also carries
/// Whisper, the engine picker and the dictation LLM selection, none of which
/// mean anything here.
private struct ModelsTab: View {
    @Environment(MeetingsAppState.self) private var state
    @State private var manager = ModelManager.shared

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                ForEach(ModelCatalog.parakeetModels) { model in
                    ModelRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        ramMB: model.approxRAMMB,
                        state: manager.parakeetStates[model.id] ?? .unknown,
                        isActive: s.settings.parakeetModelID == model.id,
                        isLoaded: ParakeetServiceHolder.shared.currentModelID == model.id,
                        isVerifying: manager.verifyingParakeet.contains(model.id),
                        select: { s.settings.parakeetModelID = model.id; state.save() },
                        download: { manager.downloadParakeet(model.id, using: ParakeetServiceHolder.shared) },
                        cancel: { manager.cancelParakeetDownload(model.id) },
                        verify: { Task { await manager.verifyParakeet(model.id, using: ParakeetServiceHolder.shared) } },
                        unload: { manager.unloadParakeet(model.id, using: ParakeetServiceHolder.shared) },
                        remove: { _ = manager.removeParakeet(model.id, using: ParakeetServiceHolder.shared) }
                    )
                }
            } header: {
                ThisMacHeader("Speech")
            } footer: {
                SectionFootnote("Turns the recording into text. Required — without it a meeting is just audio.")
            }

            Section {
                ForEach(ModelCatalog.diarizationModels) { model in
                    ModelRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        ramMB: model.approxRAMMB,
                        state: manager.diarizationStates[model.id] ?? .unknown,
                        isActive: true,
                        isLoaded: false,
                        isVerifying: manager.verifyingDiarization.contains(model.id),
                        select: {},
                        download: { manager.downloadDiarization(model.id, using: DiarizerServiceHolder.shared) },
                        cancel: { manager.cancelDiarizationDownload(model.id) },
                        verify: { Task { await manager.verifyDiarization(model.id, using: DiarizerServiceHolder.shared) } },
                        unload: { manager.unloadDiarization(model.id, using: DiarizerServiceHolder.shared) },
                        remove: { _ = manager.removeDiarization(model.id, using: DiarizerServiceHolder.shared) }
                    )
                }
            } header: {
                ThisMacHeader("Speaker separation")
            } footer: {
                SectionFootnote("Works out who spoke when on the other side of the call. Without it everyone else is one anonymous speaker; your own microphone track is always tagged as you.")
            }

            Section {
                ForEach(ModelCatalog.llmModels) { model in
                    ModelRow(
                        name: model.displayName,
                        note: model.note + (model.meetingsCapable ? "" : " · too small for meeting notes"),
                        sizeMB: model.approxSizeMB,
                        ramMB: model.approxRAMMB,
                        state: manager.llmStates[model.id] ?? .unknown,
                        isActive: s.settings.localLLMModelID == model.id,
                        isLoaded: MLXLLMServiceHolder.shared.currentModelID == model.id,
                        isVerifying: manager.verifyingLLM.contains(model.id),
                        select: { selectLocalLLM(model.id) },
                        download: { manager.downloadLLM(model.id, using: MLXLLMServiceHolder.shared) },
                        cancel: { manager.cancelLLMDownload(model.id) },
                        verify: { Task { await manager.verifyLLM(model.id, using: MLXLLMServiceHolder.shared) } },
                        unload: { manager.unloadLLM(model.id, using: MLXLLMServiceHolder.shared) },
                        remove: { _ = manager.removeLLM(model.id, using: MLXLLMServiceHolder.shared) }
                    )
                }
            } header: {
                ThisMacHeader("Local note-writing model")
            } footer: {
                SectionFootnote("Only needed when a slot on the Providers tab points at \"Local model\". Borrowing Dictator's loaded model or using a cloud provider needs nothing downloaded here.")
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refreshCachedStates() }
    }

    /// Selecting a local model updates both the per-Mac fallback and the
    /// "Local model" provider entry, so the Providers tab agrees with what was
    /// just picked here.
    private func selectLocalLLM(_ id: String) {
        state.settings.localLLMModelID = id
        if let index = state.settings.providers.firstIndex(where: { $0.kind == .localMLX }) {
            state.settings.providers[index].modelID = id
        }
        state.save()
    }
}

/// Trimmed port of Dictator's `ModelRow` — same states, same affordances, same
/// "you must download before you can select" rule (silently kicking off a
/// multi-gigabyte download on the next recording is a terrible "what just
/// happened" moment).
private struct ModelRow: View {
    let name: String
    let note: String
    let sizeMB: Int
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .opacity(canSelect ? 1 : 0.55)
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)

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
                Button {
                    confirmingRemoval = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this model from disk")
            }
            .font(.callout)
        case .notDownloaded, .unknown:
            Button("Download", action: download)
                .controlSize(.small)
        case .preparingDownload:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Fetching metadata…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CancelGlyph(action: cancel)
            }
        case .partial(let progress):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 110)
                        .tint(.orange)
                    Text("Paused · \(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Resume", action: download)
                    .controlSize(.small)
                    .help("Continue downloading from where it stopped")
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 110)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                CancelGlyph(action: cancel)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Failed").foregroundStyle(.red).font(.caption)
                    Button("Retry", action: download).controlSize(.small)
                }
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct CancelGlyph: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Cancel download")
    }
}

/// Human-readable model size. Copied from Dictator's Settings pane (it's
/// `fileprivate` there, and the two panes aren't shared).
private func formatModelSize(_ mb: Int) -> String {
    if mb >= 1024 {
        return String(format: "%.1f GB", Double(mb) / 1024)
    }
    return "\(mb) MB"
}

// MARK: - Meetings (placeholder)

/// The meeting-behaviour settings, which live in `MeetingsPane` (moved in
/// with the rest of the meetings code) — minus the "Enable Meetings" toggle
/// (installing this app is the opt-in) and the LLM-gate copy (now on the
/// Providers tab).
private struct MeetingsTab: View {
    var body: some View {
        MeetingsPane()
    }
}

// MARK: - About

private struct AboutTab: View {
    let updater: SPUUpdater

    @State private var canCheck = true

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "Version \(s) (\(b))"
        case let (s?, _):               return "Version \(s)"
        default:                        return ""
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Dictator Meetings")
                .font(.title2.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Records a call, splits the transcript by speaker, and writes the notes — on this Mac unless you point it at a cloud provider yourself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(!canCheck)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
            Link("dictator.robgough.net", destination: URL(string: "https://dictator.robgough.net")!)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
