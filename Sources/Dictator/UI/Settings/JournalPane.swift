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
                JournalCoverageRow(template: s.settings.journalPathTemplate)
                HStack {
                    Spacer()
                    Button("Reset to default") {
                        s.settings.journalPathTemplate = JournalWriter.defaultPathTemplate
                        state.save()
                    }
                    .controlSize(.small)
                    // Disabled rather than hidden: greyed out is also how you
                    // find out you're already on the default, which is a
                    // question this field otherwise can't answer.
                    .disabled(s.settings.journalPathTemplate == JournalWriter.defaultPathTemplate)
                }
            } header: {
                Text("Where it goes")
            } footer: {
                SectionFootnote("Folders are created as needed. The default nests by year and month, so a few years of daily notes stay browsable. Changing this doesn't move or delete anything you've already written.")
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
                    // Only the two fields in this section. It used to reset the
                    // file path as well — which lives in "Where it goes", so
                    // the button that fixed a mangled path was in a section
                    // nobody would think to look in, and it took the user's
                    // entry wording with it when they did find it.
                    Button("Reset to defaults") {
                        s.settings.journalEntryTemplate = JournalWriter.defaultEntryTemplate
                        s.settings.journalHeaderTemplate = JournalWriter.defaultHeaderTemplate
                        state.save()
                    }
                    .controlSize(.small)
                    .disabled(s.settings.journalEntryTemplate == JournalWriter.defaultEntryTemplate
                              && s.settings.journalHeaderTemplate == JournalWriter.defaultHeaderTemplate)
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

/// What the template in the box can actually read of what's already on disk.
///
/// Changing where entries go is the one setting here that can cost the user
/// something, and the cost is invisible at the moment of making it: the files
/// are already written, in the old shape. Rather than a warning that fires on
/// every edit and overstates the risk — a change between two numeric layouts
/// loses nothing, because the date can still be read from the digits — this
/// counts the real archive and says what would actually happen.
///
/// Recomputed as the field is typed in, debounced, and off the main actor: it's
/// a directory walk, and Settings shouldn't stutter under it.
private struct JournalCoverageRow: View {
    let template: String

    @State private var coverage: JournalCoverage?

    var body: some View {
        Group {
            if let coverage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: coverage.tone == .warning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(coverage.tone == .warning
                                         ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(coverage.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let examples = coverage.examplesLine {
                            Text(examples)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .task(id: template) {
            // Typing a template goes through a lot of half-finished paths on
            // the way to a real one; none of them deserve a directory walk.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            coverage = await measure()
        }
    }

    private func measure() async -> JournalCoverage? {
        guard let root = JournalWriter.root(pathTemplate: template) else { return nil }
        let pattern = JournalPathPattern.make(pathTemplate: template)
        return await Task.detached {
            JournalCoverage.measure(root: root, pattern: pattern)
        }.value
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
