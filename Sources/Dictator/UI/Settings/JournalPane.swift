import SwiftUI
import AppKit
import KeyboardShortcuts

/// Journal settings.
///
/// Its own sidebar section rather than a block inside General: journalling is
/// a third capture flow with its own hotkey, its own destination and its own
/// colour, and three template fields buried under "Performance" was never
/// going to be findable.
struct JournalPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
                Picker("Trigger", selection: $s.settings.journalTriggerMode) {
                    ForEach(TriggerMode.allCases.filter { mode in
                        // Hide whatever the other two hotkeys are using, so
                        // three flows can't end up on one physical key.
                        mode == .keyboardShortcut
                            || (mode != s.settings.triggerMode && mode != s.settings.assistantTriggerMode)
                    }) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: s.settings.journalTriggerMode) { _, _ in state.save() }

                if s.settings.journalTriggerMode == .keyboardShortcut {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleJournal)
                        Button("Reset") { state.resetJournalKeyboardShortcut() }
                            .controlSize(.small)
                    }
                }

                Picker("Style", selection: Binding(
                    get: { s.settings.journalModeID ?? s.settings.defaultModeID },
                    set: { s.settings.journalModeID = $0; state.save() }
                )) {
                    ForEach(state.settings.modes) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                .pickerStyle(.menu)
                .help("Which mode processes a journal dictation. Notes usually want more cleanup than typing does.")
            } header: {
                Text("Hotkey")
            } footer: {
                SectionFootnote("Hold to record, release to save. Nothing is pasted — the app you're in is never touched.")
            }

            Section {
                TemplateField(
                    title: "File",
                    prompt: JournalWriter.defaultPathTemplate,
                    text: $s.settings.journalPathTemplate,
                    multiline: false,
                    onChange: { state.save() }
                )
                JournalDestinationRow(template: s.settings.journalPathTemplate)
            } header: {
                Text("Where it goes")
            } footer: {
                SectionFootnote("Folders are created as needed. The default nests by year and month, so a few years of daily notes stay browsable.")
            }

            Section {
                TemplateField(
                    title: "Each entry",
                    prompt: JournalWriter.defaultEntryTemplate,
                    text: $s.settings.journalEntryTemplate,
                    multiline: true,
                    onChange: { state.save() }
                )
                TemplateField(
                    title: "Top of a new file",
                    prompt: JournalWriter.defaultHeaderTemplate,
                    text: $s.settings.journalHeaderTemplate,
                    multiline: true,
                    onChange: { state.save() }
                )
                HStack {
                    Spacer()
                    Button("Reset to defaults") {
                        s.settings.journalPathTemplate = JournalWriter.defaultPathTemplate
                        s.settings.journalEntryTemplate = JournalWriter.defaultEntryTemplate
                        s.settings.journalHeaderTemplate = JournalWriter.defaultHeaderTemplate
                        state.save()
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("What gets written")
            } footer: {
                SectionFootnote("Anything in braces is a date format: {yyyy}, {MM}, {MMMM}, {dd}, {EEEE}, {HH}, {mm}. {text} is the dictation itself and {app} the app you were in. Entries are appended, never overwritten.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

/// A template field, labelled above rather than beside.
///
/// Grouped `Form` rows right-align their value, which turns a template into a
/// few visible characters — unreadable for the one control that has to be
/// exactly right. The entry templates are also genuinely multi-line (the
/// default starts with a blank line and a heading), so a single-line
/// `TextField` would render real newlines as invisible nothing and give the
/// user no way to type one.
private struct TemplateField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let multiline: Bool
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if multiline {
                TextEditor(text: $text)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.25))
                    )
                    .onChange(of: text) { _, _ in onChange() }
            } else {
                TextField("", text: $text, prompt: Text(prompt))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .onSubmit(onChange)
                    .onChange(of: text) { _, _ in onChange() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where today's entry will land, plus the two things you'd want to do with
/// it: open the file, or show it in Finder.
///
/// A template language nobody can see the output of is a template language
/// nobody uses — and this is the field where a typo silently sends every
/// entry somewhere unexpected. The buttons disable rather than disappear when
/// today's file doesn't exist yet, so the row doesn't reflow the moment you
/// write your first entry.
private struct JournalDestinationRow: View {
    let template: String

    private var url: URL? {
        try? JournalWriter.resolvedURL(pathTemplate: template)
    }

    private var exists: Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: url == nil ? "exclamationmark.triangle.fill" : "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(url == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                Text(displayPath ?? "That template doesn\u{2019}t resolve to a file.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Open") {
                    if let url { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
                .disabled(!exists)

                Button("Show in Finder") {
                    if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .controlSize(.small)
                .disabled(url == nil)

                if !exists, url != nil {
                    Text("Not written yet \u{2014} it appears with your first entry today.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Tilde-abbreviated so a long home directory doesn't push the
    /// interesting end of the path out of view.
    private var displayPath: String? {
        guard let url else { return nil }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }
}
