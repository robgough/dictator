import SwiftUI
import AppKit
import KeyboardShortcuts

/// Assistant Mode: its own hotkey, its own prompt, its own context switch.
/// A separate flow from dictation, so it gets a separate section rather than
/// living inside a dictation mode.
struct AssistantPane: View {
    @Environment(AppState.self) private var state
    @State private var showPromptSheet = false
    @State private var showForgetConfirm = false

    /// Read through `AssistantMemory` rather than cached in `@State`: the file
    /// is hand-editable, so the store re-reads it when its mtime moves and the
    /// count follows without this view having to watch anything.
    private var memoryCount: Int { AssistantMemory.shared.entries.count }

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Picker("Trigger", selection: $s.settings.assistantTriggerMode) {
                    ForEach(TriggerMode.allCases.filter { mode in
                        // Hide whatever the dictation trigger is using so the
                        // two hotkeys can't collide on the same physical key.
                        mode == .keyboardShortcut || mode != s.settings.triggerMode
                    }) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: s.settings.assistantTriggerMode) { _, _ in state.save() }

                if s.settings.assistantTriggerMode == .keyboardShortcut {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleAssistant)
                        Button("Reset") {
                            state.resetAssistantKeyboardShortcut()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Hotkey")
            } footer: {
                SectionFootnote("Hold with text selected and say what to do.")
            }

            Section("Prompt") {
                LabeledContent("Prompt") {
                    Button("Customise…") { showPromptSheet = true }
                }
                .help("Add your own instructions, or replace the built-in prompt entirely.")
            }

            Section {
                InstructionsField("How the assistant should sound…",
                                  text: $s.settings.assistantPersona) { state.save() }
                HStack {
                    Spacer()
                    Button("Reset") {
                        s.settings.assistantPersona = DictatorSettings.builtinAssistantPersona
                        state.save()
                    }
                    .controlSize(.small)
                    .disabled(s.settings.assistantPersona == DictatorSettings.builtinAssistantPersona)
                }
            } header: {
                Text("Personality")
            } footer: {
                SectionFootnote("Shapes drafts and answers, never your own text.")
            }

            Section {
                Toggle("Remember things I tell it", isOn: $s.settings.assistantMemoryEnabled)
                    .onChange(of: s.settings.assistantMemoryEnabled) { _, _ in state.save() }
                if s.settings.assistantMemoryEnabled {
                    LabeledContent(memoryCount == 1 ? "1 remembered" : "\(memoryCount) remembered") {
                        HStack(spacing: 8) {
                            Button("Open file") { AssistantMemory.shared.openInEditor() }
                            Button("Forget all…") { showForgetConfirm = true }
                                .disabled(memoryCount == 0)
                        }
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                SectionFootnote("Kept in your synced folder as assistant-memory.md, one line each.")
            }

            if WindowVisionContext.isSupported {
                Section {
                    Toggle("Read the focused window with vision",
                           isOn: $s.settings.assistantWindowVisionContextEnabled)
                        .onChange(of: s.settings.assistantWindowVisionContextEnabled) { _, enabled in
                            if enabled { ScreenRecordingPermission.request() }
                            state.save()
                        }
                } header: {
                    Text("Context")
                } footer: {
                    SectionFootnote("Reads on-screen names, on-device, so replies use them.")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .task { AssistantMemory.shared.refresh() }
        .sheet(isPresented: $showPromptSheet) {
            AssistantPromptSheet()
        }
        .confirmationDialog("Forget everything the assistant remembers?",
                            isPresented: $showForgetConfirm,
                            titleVisibility: .visible) {
            Button("Forget All", role: .destructive) { AssistantMemory.shared.forgetAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears assistant-memory.md. It can't be undone.")
        }
    }
}

/// Hosts the shared `PromptCustomiser` (addendum / full override / view
/// built-in) in a sheet — the pane itself carries no editor, per the "no
/// TextEditor in a pane" rule.
private struct AssistantPromptSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Assistant prompt").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            PromptCustomiser(
                description: "Used for the Assistant hotkey.",
                builtin: DictatorSettings.builtinAssistantPrompt,
                addendum: $s.settings.assistantPromptAddendum,
                override: $s.settings.assistantPromptOverride
            ) { state.save() }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 640, height: 560)
    }
}
