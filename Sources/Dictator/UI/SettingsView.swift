import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
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
        }
        .padding(20)
        .environment(state)
    }
}

private struct DictionaryPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom spellings & corrections")
                        .font(.headline)
                    Text("Applied right after the formatter pass. Matches are word-aware and case-insensitive by default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    s.settings.vocabulary.append(VocabularyEntry(pattern: "", replacement: ""))
                    state.save()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if s.settings.vocabulary.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Your dictionary is empty",
                    systemImage: "character.book.closed",
                    description: Text("Click **Add** to create your first rule. Example: pattern \"github\" → replacement \"GitHub\".")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach($s.settings.vocabulary) { $entry in
                            DictionaryEntryRow(entry: $entry) {
                                s.settings.vocabulary.removeAll { $0.id == entry.id }
                                state.save()
                            }
                            .onChange(of: entry) { _, _ in state.save() }
                        }
                    }
                }
                .frame(minHeight: 280)
            }
        }
    }
}

private struct DictionaryEntryRow: View {
    @Binding var entry: VocabularyEntry
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heard").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. github", text: $entry.pattern)
                        .textFieldStyle(.roundedBorder)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replace with").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. GitHub", text: $entry.replacement)
                        .textFieldStyle(.roundedBorder)
                }
                VStack {
                    Spacer()
                    Button(role: .destructive, action: remove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 16) {
                Toggle("Case-sensitive", isOn: $entry.caseSensitive)
                Toggle("Whole word only", isOn: $entry.wholeWord)
                Spacer()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
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
                Spacer()
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Recorded dictations will appear here.")
                )
                Spacer()
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Currently using")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(manager.activeInputDeviceName())
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                Spacer()
                Button {
                    manager.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))

            Text("Drag to set priority. The top-most **connected** device is used.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(manager.knownDevices) { device in
                    DeviceRow(device: device, connected: manager.isConnected(device.uid)) {
                        manager.forget(uid: device.uid)
                    }
                }
                .onMove { source, destination in
                    manager.move(from: source, to: destination)
                }
            }
            .listStyle(.bordered)
            .frame(minHeight: 220)

            if manager.knownDevices.isEmpty {
                Text("No input devices seen yet. Plug one in and click Refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: AudioDevice
    let connected: Bool
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connected ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    if let manufacturer = device.manufacturer, !manufacturer.isEmpty, manufacturer != "Apple" {
                        Text(manufacturer)
                    }
                    Text(connected ? "Connected" : "Last seen \(Self.relative(device.lastSeen))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                forget()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget this device")
        }
        .padding(.vertical, 2)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct GeneralPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var s = state
        Form {
            Section("Hotkey") {
                Picker("Trigger", selection: $s.settings.triggerMode) {
                    ForEach(TriggerMode.allCases) { mode in
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
                            HotkeyBinder.shared.resetKeyboardShortcutToDefault()
                        }
                        .controlSize(.small)
                    }
                    Text("Hold the shortcut to record, release to transcribe. Use **Reset** if the recorder gets cleared.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Hold the **\(s.settings.triggerMode.label)** key to dictate. Release to transcribe.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                Text("Loads Whisper and the LLM into memory at launch (~3 GB resident). First dictation is then instant.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Tidy grammar (third pass)", isOn: $s.settings.grammarPassEnabled)
                    .onChange(of: s.settings.grammarPassEnabled) { _, _ in state.save() }
                HStack {
                    Text("Discard if more than")
                    Spacer()
                    Stepper(value: $s.settings.grammarPassMaxEditFraction, in: 0.05...0.40, step: 0.05) {
                        Text("\(Int(s.settings.grammarPassMaxEditFraction * 100))% of words change")
                            .font(.callout)
                            .monospacedDigit()
                    }
                    .onChange(of: s.settings.grammarPassMaxEditFraction) { _, _ in state.save() }
                }
                .disabled(!s.settings.grammarPassEnabled)
                Text("Fixes obvious grammar errors (contractions, agreement, duplicate words). The pass is rejected if too many words change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle("Restructure long dictations into paragraphs / lists", isOn: $s.settings.structuralPassEnabled)
                    .onChange(of: s.settings.structuralPassEnabled) { _, _ in state.save() }
                HStack {
                    Text("Trigger when transcript reaches")
                    Spacer()
                    Stepper(value: $s.settings.structuralPassMinWords, in: 10...200, step: 5) {
                        Text("\(s.settings.structuralPassMinWords) words")
                            .font(.callout)
                            .monospacedDigit()
                    }
                    .onChange(of: s.settings.structuralPassMinWords) { _, _ in state.save() }
                }
                .disabled(!s.settings.structuralPassEnabled)
                Text("Adds paragraph breaks and bullet lists for longer dictations. The pass is rejected if it changes any of your words.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Permissions") {
                AccessibilityStatusRow()
                PermissionRow(label: "Microphone", hint: "System Settings → Privacy & Security → Microphone")
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let label: String
    let hint: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).fontWeight(.medium)
            Text(hint).foregroundStyle(.secondary).font(.caption)
        }
        .font(.callout)
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
                     : "Not granted — Dictator will copy to clipboard but cannot paste. Click below to open System Settings, then enable Dictator in Accessibility.")
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Spacer()
            if !granted {
                Button("Open Settings") {
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

private struct ModelsPane: View {
    @Environment(AppState.self) private var state
    @State private var manager = ModelManager.shared

    var body: some View {
        @Bindable var s = state
        Form {
            Section("Speech-to-text (WhisperKit)") {
                Picker("Model", selection: $s.settings.whisperModelID) {
                    ForEach(ModelCatalog.whisperModels) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                .onChange(of: s.settings.whisperModelID) { _, _ in state.save() }

                if let model = ModelCatalog.whisper(id: s.settings.whisperModelID) {
                    ModelStatusRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        state: manager.whisperStates[model.id] ?? .unknown,
                        download: {
                            Task { await manager.downloadWhisper(model.id, using: TranscriptionServiceHolder.shared) }
                        }
                    )
                }
            }
            Section("Formatting LLM (MLX)") {
                Picker("Model", selection: $s.settings.llmModelID) {
                    ForEach(ModelCatalog.llmModels) { m in
                        Text(m.displayName).tag(m.id)
                    }
                }
                .onChange(of: s.settings.llmModelID) { _, _ in state.save() }

                if let model = ModelCatalog.llm(id: s.settings.llmModelID) {
                    ModelStatusRow(
                        name: model.displayName,
                        note: model.note,
                        sizeMB: model.approxSizeMB,
                        state: manager.llmStates[model.id] ?? .unknown,
                        download: {
                            Task { await manager.downloadLLM(model.id, using: LLMServiceHolder.shared) }
                        }
                    )
                }
            }
            Section {
                Button("Reveal Models in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ModelStorage.root()])
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { manager.refreshCachedStates() }
    }
}

private struct ModelStatusRow: View {
    let name: String
    let note: String
    let sizeMB: Int
    let state: ModelDownloadState
    let download: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text("\(note) · ~\(sizeMB) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusView
        }
    }

    @ViewBuilder private var statusView: some View {
        switch state {
        case .ready:
            Label("Installed", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
                .font(.callout)
        case .notDownloaded, .unknown:
            Button("Download", action: download)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading(let p):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: p)
                    .frame(width: 130)
                Text("\(Int(p * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 4) {
                Text("Failed").foregroundStyle(.red).font(.caption)
                Button("Retry", action: download)
                    .controlSize(.small)
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

private struct PromptPane: View {
    @Environment(AppState.self) private var state
    @State private var selected: Tab = .formatting

    enum Tab: String, CaseIterable, Identifiable {
        case formatting = "Pass 1 · Formatting"
        case grammar    = "Pass 2 · Grammar"
        case structure  = "Pass 3 · Structure"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $selected) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch selected {
            case .formatting: formattingEditor
            case .grammar:    grammarEditor
            case .structure:  structuralEditor
            }
        }
    }

    private var formattingEditor: some View {
        @Bindable var s = state
        return VStack(alignment: .leading, spacing: 8) {
            Text("Punctuation, emojis, capitalisation. Runs on every dictation.")
                .font(.callout)
                .foregroundStyle(.secondary)
            promptEditor(text: $s.settings.systemPrompt) {
                s.settings.systemPrompt = DictatorSettings.defaultPrompt
                state.save()
            }
            .onChange(of: s.settings.systemPrompt) { _, _ in state.save() }
        }
    }

    private var grammarEditor: some View {
        @Bindable var s = state
        return VStack(alignment: .leading, spacing: 8) {
            Text("Fixes obvious grammar errors after pass 1. Runs only when **Tidy grammar** is enabled. Result is discarded if too many words change.")
                .font(.callout)
                .foregroundStyle(.secondary)
            promptEditor(text: $s.settings.grammarPrompt) {
                s.settings.grammarPrompt = DictatorSettings.defaultGrammarPrompt
                state.save()
            }
            .onChange(of: s.settings.grammarPrompt) { _, _ in state.save() }
        }
    }

    private var structuralEditor: some View {
        @Bindable var s = state
        return VStack(alignment: .leading, spacing: 8) {
            Text("Adds paragraph breaks and bullet lists. Runs only when **Restructure long dictations** is enabled and the transcript is long enough. Word changes are rejected automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            promptEditor(text: $s.settings.structuralPrompt) {
                s.settings.structuralPrompt = DictatorSettings.defaultStructuralPrompt
                state.save()
            }
            .onChange(of: s.settings.structuralPrompt) { _, _ in state.save() }
        }
    }

    @ViewBuilder
    private func promptEditor(text: Binding<String>, reset: @escaping () -> Void) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
            .frame(minHeight: 260)
        HStack {
            Button("Reset to default", action: reset)
            Spacer()
        }
    }
}
