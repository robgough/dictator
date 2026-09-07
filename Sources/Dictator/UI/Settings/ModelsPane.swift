import SwiftUI
import AppKit
import MLX

/// Sub-divisions inside the Models pane: the two engine choices and a
/// diagnostics readout. Internal, not private: `SettingsShellModel` holds the
/// selection and the toolbar's segmented control (SettingsShell.swift) renders
/// the cases.
enum ModelsSubPane: String, CaseIterable, Identifiable {
    case transcription = "Transcription"
    case formatting = "Formatting"
    case memory = "Memory"
    var id: String { rawValue }
}

struct ModelsPane: View {
    @State private var manager = ModelManager.shared
    /// The sub-pane tabs live centred in the window toolbar (SettingsShell)
    /// and drive `shell.modelsTab`.
    let shell: SettingsShellModel

    var body: some View {
        VStack(spacing: 0) {
            switch shell.modelsTab {
            case .transcription: TranscriptionModelsPane()
            case .formatting: FormattingModelsPane()
            case .memory: MemoryModelsPane()
            }

            SectionFootnote("Model choice isn't synced between Macs.")
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        // Refresh on-disk download state when the user opens the Models
        // tab. Each sub-pane reads from the same shared ModelManager so a
        // single refresh covers all three. Reset to Transcription on each
        // entry — that's the most common reason to come here, and landing
        // on Memory first would bury the actual model lists.
        .onAppear {
            shell.modelsTab = .transcription
            manager.refreshCachedStates()
        }
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
                SectionFootnote("Parakeet runs on the Neural Engine and is much faster; Whisper is the fallback.")
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
                Toggle("Show real-time transcription in HUD", isOn: Binding(
                    get: { s.settings.realtimeInterimEnabled },
                    set: { newValue in
                        s.settings.realtimeInterimEnabled = newValue
                        state.save()
                    }
                ))
                .disabled(s.settings.transcriptionEngine != .parakeet)
                .help("Streams a draft transcript into the HUD while you hold the hotkey. The final output is unchanged.")
            } footer: {
                if s.settings.transcriptionEngine != .parakeet {
                    SectionFootnote("Parakeet only.")
                }
            }

            Section("Parakeet models") {
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
            }

            Section("Whisper models") {
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
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

/// Formatting sub-pane: top-level engine picker (None / Apple Foundation / MLX),
/// then engine-specific content underneath. The engine choice drives both which
/// backend runs the dictation-cleanup passes AND which one powers Assistant
/// Mode — they're not separable.
private struct FormattingModelsPane: View {
    @Environment(AppState.self) private var state
    @State private var manager = ModelManager.shared
    @State private var mlxLLM = MLXLLMServiceHolder.shared

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Picker("LLM engine", selection: Binding(
                    get: { s.settings.llmEngine },
                    set: { newValue in
                        s.settings.llmEngine = newValue
                        state.save()
                    }
                )) {
                    Text("Apple Foundation").tag(LLMEngineKind.apple)
                    Text("MLX (downloaded)").tag(LLMEngineKind.mlx)
                    Text("None").tag(LLMEngineKind.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Engine")
            } footer: {
                // One line, and it says the thing that matters for the current
                // choice — rather than a paragraph covering all three.
                if s.settings.llmEngine == .none {
                    SectionFootnote("Raw transcripts only; the assistant is unavailable.")
                } else {
                    SectionFootnote("Apple's on-device model needs Apple Intelligence; MLX models download once.")
                }
            }

            switch s.settings.llmEngine {
            case .none:
                EmptyView()
            case .apple:
                Section("Apple Foundation Model") {
                    AppleFoundationStatusRow()
                }
            case .mlx:
                Section("MLX models") {
                    ForEach(ModelCatalog.llmModels) { model in
                        ModelRow(
                            name: model.displayName,
                            note: model.note,
                            sizeMB: model.approxSizeMB,
                            ramMB: model.approxRAMMB,
                            state: manager.llmStates[model.id] ?? .unknown,
                            isActive: s.settings.llmModelID == model.id,
                            isLoaded: mlxLLM.currentModelID == model.id,
                            isVerifying: manager.verifyingLLM.contains(model.id),
                            select: {
                                s.settings.llmModelID = model.id
                                state.save()
                            },
                            download: {
                                manager.downloadLLM(model.id, using: MLXLLMServiceHolder.shared)
                            },
                            cancel: {
                                manager.cancelLLMDownload(model.id)
                            },
                            verify: {
                                Task { await manager.verifyLLM(model.id, using: MLXLLMServiceHolder.shared) }
                            },
                            unload: {
                                manager.unloadLLM(model.id, using: MLXLLMServiceHolder.shared)
                            },
                            remove: {
                                manager.removeLLM(model.id, using: MLXLLMServiceHolder.shared)
                            }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Renders the current `SystemLanguageModel.default.availability` state with a
/// matching icon, explanation, and (when the user has actionable next steps) a
/// shortcut to System Settings → Apple Intelligence. The wording comes from
/// `AppleFoundationAvailability`, shared with Dictator Meetings.
private struct AppleFoundationStatusRow: View {
    @State private var availability: AppleFoundationAvailability.Reading = .unknown

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: availability.iconName)
                        .foregroundStyle(availability.tint)
                    Text(availability.headline).fontWeight(.medium)
                }
                Text(availability.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if availability == .appleIntelligenceOff {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppleIntelligence") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear { availability = AppleFoundationAvailability.Reading.current() }
        // Re-poll every couple of seconds while the pane is visible so the
        // status flips live when the user toggles Apple Intelligence on/off
        // from System Settings without bouncing back to Dictator.
        .task {
            while !Task.isCancelled {
                availability = AppleFoundationAvailability.Reading.current()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Memory sub-pane (was "Stats"): live memory readout — physical RAM, current
/// footprint, the sum of the selected combo's approx RAM cost, and MLX's GPU
/// buffer accounting. Numbers only; the explanations that used to sit under
/// them are tooltips now.
private struct MemoryModelsPane: View {
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
        if settings.llmEngine == .mlx {
            total += ModelCatalog.llm(id: settings.llmModelID)?.approxRAMMB ?? 0
        }
        // Apple Foundation Model is system-resident — its weights don't count
        // against Dictator's RSS.
        return total
    }

    var body: some View {
        @Bindable var s = state
        Form {
            Section("Memory") {
                LabeledContent("This Mac") {
                    Text(memory.physicalDisplay)
                        .monospacedDigit()
                }
                LabeledContent("Dictator using") {
                    Text(memory.residentDisplay)
                        .monospacedDigit()
                }
                .help("Mirrors Activity Monitor's footprint; actual physical RAM is often less because macOS compresses cold pages.")
                LabeledContent("Selected models, loaded") {
                    Text("≈\(formatModelSize(selectedComboRAMMB(s.settings)))")
                        .monospacedDigit()
                }
            }

            Section("MLX (LLM)") {
                LabeledContent("Active") {
                    Text(Self.formatBytes(mlxSnapshot?.activeMemory ?? 0))
                        .monospacedDigit()
                }
                .help("Buffers held by current inference.")
                LabeledContent("Cache") {
                    Text(Self.formatBytes(mlxSnapshot?.cacheMemory ?? 0))
                        .monospacedDigit()
                }
                .help("Recyclable buffer pool, capped at 512 MB.")
                LabeledContent("Peak since launch") {
                    Text(Self.formatBytes(mlxSnapshot?.peakMemory ?? 0))
                        .monospacedDigit()
                }
                .help("Highest active reading since launch.")
            }
        }
        .formStyle(.grouped)
        // Refresh the live memory section on a 2 s cadence while the Memory
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
