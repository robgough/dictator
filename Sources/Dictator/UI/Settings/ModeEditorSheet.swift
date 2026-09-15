import SwiftUI
import AppKit

/// Editor for one `DictationMode`, presented as a sheet from the Dictation →
/// Modes list. It replaced a hand-rolled drill-in that owned window-title and
/// back-button state in the toolbar; a sheet keeps the window title equal to
/// the section title and carries its own.
///
/// Every change saves immediately through `onChange` — there's no Cancel, and
/// "Done" only dismisses.
struct ModeEditorSheet: View {
    @Binding var mode: DictationMode
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onChange: () -> Void

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var showCustomPromptSheet = false
    @State private var newURLPattern = ""

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            Divider()
            Form {
                styleSection
                if mode.style != .raw { extraInstructionsSection }
                if !mode.isLocked {
                    appsSection
                    websitesSection
                }
                languageSection
                optionsSection
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            Divider()
            bottomBar
        }
        .frame(width: 560, height: 620)
        .sheet(isPresented: $showCustomPromptSheet) {
            CustomPromptSheet(customPrompt: $mode.customPrompt, onChange: onChange)
        }
    }

    // MARK: - Chrome

    /// The sheet's own title. Locked modes (Quick) render the name as plain
    /// text with a lock glyph — their identity is the point of the mode.
    private var titleRow: some View {
        HStack(spacing: 8) {
            if mode.isLocked {
                Text(mode.name)
                    .font(.title3.weight(.semibold))
                Image(systemName: "lock.fill")
                    .foregroundStyle(.tertiary)
                    .help("Quick is built in: its name and Raw style are fixed.")
            } else {
                TextField("Mode name", text: $mode.name)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { onChange() }
                    .onChange(of: mode.name) { _, _ in onChange() }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var bottomBar: some View {
        HStack {
            if !isDefault {
                Button("Make default", action: onMakeDefault)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var styleSection: some View {
        Section {
            Picker("Style", selection: $mode.style) {
                ForEach(DictationStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.menu)
            .disabled(mode.isLocked)
            .onChange(of: mode.style) { _, _ in onChange() }

            Text(mode.style.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if mode.style == .custom {
                Button {
                    showCustomPromptSheet = true
                } label: {
                    Label("Edit prompt…", systemImage: "doc.text")
                }
            }
        } header: {
            Text("Style")
        } footer: {
            if state.settings.llmEngine == .none {
                SectionFootnote("AI styles need an LLM (see Models).")
            }
        }
    }


    /// A sentence or two of preference for this mode. Full width and
    /// left-aligned: a labelled field in a grouped Form renders its value
    /// trailing-aligned, which is right for a name and unreadable for prose.
    private var extraInstructionsSection: some View {
        Section {
            InstructionsField(
                "Add instructions for this mode…",
                text: $mode.extraInstructions,
                onChange: onChange
            )
        } header: {
            Text("Extra instructions")
        } footer: {
            SectionFootnote("Added to every AI pass in this mode, after your General AI instructions.")
        }
    }

    private var appsSection: some View {
        Section {
            ForEach(mode.appBundleIDs, id: \.self) { bundleID in
                AppBindingRow(bundleID: bundleID) {
                    mode.appBundleIDs.removeAll(where: { $0 == bundleID })
                    onChange()
                }
            }
            Button {
                pickApp()
            } label: {
                Label("Add app…", systemImage: "plus")
            }
        } header: {
            Text("Apps")
        } footer: {
            SectionFootnote("Switches to this mode when one of these apps is in front.")
        }
    }

    /// Site bindings. Separate from the Apps section rather than folded into
    /// it because they're typed, not picked, and because they win over an app
    /// binding when both could match — worth showing as its own idea.
    private var websitesSection: some View {
        Section {
            ForEach(mode.urlPatterns, id: \.self) { pattern in
                URLBindingRow(pattern: pattern) {
                    mode.urlPatterns.removeAll(where: { $0 == pattern })
                    onChange()
                }
            }
            HStack(spacing: 6) {
                TextField("gmail.com", text: $newURLPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addURLPattern)
                Button("Add", action: addURLPattern)
                    .disabled(newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Websites")
        } footer: {
            SectionFootnote("Switches to this mode when the browser in front is on a matching page. Beats an app match, so a site rule wins over a rule for the browser itself. Needs Accessibility.")
        }
    }

    /// Language. Two separate ideas that look similar and aren't: what the
    /// recogniser should expect to hear, and what the delivered text should be
    /// written in.
    private var languageSection: some View {
        Section {
            Picker("I speak", selection: $mode.spokenLanguage) {
                Text("Detect automatically").tag(DictationLanguage.auto)
                Divider()
                ForEach(DictationLanguage.selectable) { language in
                    Text(language.label).tag(language)
                }
            }
            .onChange(of: mode.spokenLanguage) { _, _ in onChange() }
            .help("Tells the transcription model which language to expect. It still detects automatically when this is left alone.")

            Picker("Write it in", selection: $mode.outputLanguage) {
                Text("Same language I spoke").tag(DictationLanguage.auto)
                Divider()
                ForEach(DictationLanguage.selectable) { language in
                    Text(language.label).tag(language)
                }
            }
            .onChange(of: mode.outputLanguage) { _, _ in onChange() }
            .help("Translates the dictation before it's delivered. Runs on-device as one extra pass, so it needs a language model.")
        } header: {
            Text("Language")
        } footer: {
            languageFootnote
        }
    }

    @ViewBuilder
    private var languageFootnote: some View {
        if mode.translationTarget != nil, state.settings.llmEngine == .none {
            SectionFootnote("Translation needs a language model (see Models). Right now the dictation will be delivered as spoken.")
        } else if state.settings.transcriptionEngine == .parakeet, !mode.spokenLanguage.isParakeetSupported {
            SectionFootnote("Parakeet doesn't handle \(mode.spokenLanguage.label). Switch to Whisper in Models, or this mode will transcribe poorly.")
        } else if mode.translationTarget != nil {
            SectionFootnote("Dictate in \(mode.spokenLanguage == .auto ? "any language" : mode.spokenLanguage.label), get \(mode.outputLanguage.label).")
        } else {
            SectionFootnote("Leave both alone unless you dictate in more than one language.")
        }
    }

    private func addURLPattern() {
        let trimmed = newURLPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return }
        // Store the normalized form so "https://www.gmail.com/" and
        // "gmail.com" don't sit in the list as two different-looking rules
        // that behave identically.
        let pattern = BrowserURLReader.normalize(trimmed) ?? trimmed
        if !mode.urlPatterns.contains(pattern) {
            mode.urlPatterns.append(pattern)
            onChange()
        }
        newURLPattern = ""
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Spoken cues", isOn: spokenCuesBinding)
                .help("Turns \u{201C}comma\u{201D}, \u{201C}twenty-five\u{201D} and friends into punctuation, digits and symbols.")
            // Family toggles save from their own setters rather than an
            // `.onChange` modifier: the master switch above writes all five
            // fields directly, and `.onChange` would then fire five extra
            // saves for one flip.
            DisclosureGroup("Customise") {
                Toggle("Punctuation", isOn: cueBinding(\.punctuationCuesEnabled))
                    .help("\u{201C}comma\u{201D} \u{2192} \u{201C},\u{201D}   \u{201C}new line\u{201D} \u{2192} \u{23CE}")
                Toggle("Numbers", isOn: cueBinding(\.numberCuesEnabled))
                    .help("\u{201C}twenty-five\u{201D} \u{2192} \u{201C}25\u{201D}   \u{201C}5 plus 3\u{201D} \u{2192} \u{201C}5 + 3\u{201D}")
                Toggle("Times", isOn: cueBinding(\.timeCuesEnabled))
                    .help("\u{201C}ten thirty PM\u{201D} \u{2192} \u{201C}10:30 PM\u{201D}")
                Toggle("Currency", isOn: cueBinding(\.currencyCuesEnabled))
                    .help("\u{201C}five dollars\u{201D} \u{2192} \u{201C}$5\u{201D}")
                Toggle("Emoji", isOn: cueBinding(\.emojiCuesEnabled))
                    .help("\u{201C}fire emoji\u{201D} \u{2192} \u{1F525}")
            }

            Toggle("Apply dictionary", isOn: $mode.vocabularyEnabled)
                .onChange(of: mode.vocabularyEnabled) { _, _ in onChange() }
                .help("Applies your Dictionary rules. The list is shared; this switch is per mode.")

            Toggle("Use text around the cursor", isOn: $mode.contextAwarenessEnabled)
                .onChange(of: mode.contextAwarenessEnabled) { _, _ in onChange() }
                .help("Reads a little text either side of the cursor so names match the document and the paste joins cleanly. On-device, never stored; password fields are never read.")

            Toggle("Press Return after pasting", isOn: $mode.pressReturnAfterPaste)
                .onChange(of: mode.pressReturnAfterPaste) { _, _ in onChange() }
                .help("Submits in chat and search boxes; inserts a blank line in editors.")

            Toggle("End with a trailing space", isOn: $mode.appendTrailingSpace)
                .onChange(of: mode.appendTrailingSpace) { _, _ in onChange() }
                .help("For back-to-back dictation in a terminal or chat.")

            if !mode.isLocked {
                Toggle("Include in Tab cycle", isOn: $mode.includeInCycle)
                    .onChange(of: mode.includeInCycle) { _, _ in onChange() }
                    .help("Tapping Tab during a recording rotates through the cycle-enabled modes, in list order.")
            }
        }
    }

    /// One cue family, saving on write. See the comment in `optionsSection`.
    private func cueBinding(_ key: WritableKeyPath<DictationMode, Bool>) -> Binding<Bool> {
        Binding(
            get: { mode[keyPath: key] },
            set: { newValue in
                mode[keyPath: key] = newValue
                onChange()
            }
        )
    }

    /// Master switch over the five cue families: on when any family is on,
    /// and flipping it writes all five. The families themselves stay
    /// independently settable in the disclosure group underneath.
    private var spokenCuesBinding: Binding<Bool> {
        Binding(
            get: {
                mode.punctuationCuesEnabled || mode.numberCuesEnabled || mode.timeCuesEnabled
                    || mode.currencyCuesEnabled || mode.emojiCuesEnabled
            },
            set: { on in
                mode.punctuationCuesEnabled = on
                mode.numberCuesEnabled = on
                mode.timeCuesEnabled = on
                mode.currencyCuesEnabled = on
                mode.emojiCuesEnabled = on
                onChange()
            }
        )
    }

    /// Opens NSOpenPanel filtered to `.application`, extracts the bundle ID,
    /// and appends it to this mode's bindings (if not already present).
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Pick an app to auto-activate this mode in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        if !mode.appBundleIDs.contains(bundleID) {
            mode.appBundleIDs.append(bundleID)
            onChange()
        }
    }
}

/// Full prompt editor for a `.custom` mode: the single system prompt used for
/// the mode's one AI pass, plus a reset back to the built-in Format prompt.
/// A `TextEditor` is fine here — it's a sheet, not a pane.
private struct CustomPromptSheet: View {
    @Binding var customPrompt: String
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Custom prompt").font(.headline)
                Spacer()
                Button("Reset to built-in") {
                    customPrompt = DictatorSettings.builtinFormattingPrompt
                    onChange()
                }
                .controlSize(.small)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            PromptEditor(text: $customPrompt, onChange: onChange)
                .padding(12)
        }
        .frame(width: 720, height: 520)
    }
}

/// One row in the website-bindings list. Plainer than `AppBindingRow` — there
/// is no icon to resolve, and the pattern is already the display name.
private struct URLBindingRow: View {
    let pattern: String
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
            Text(pattern)
                .lineLimit(1)
            Spacer()
            if hovering {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .help("Matches any page whose address contains \(pattern)")
        .onHover { hovering = $0 }
    }
}

/// One row in the app-bindings list. Shows the app's icon (resolved from the
/// bundle ID via NSWorkspace) and either its display name or, if unresolvable,
/// the raw bundle ID. The remove button is on hover so the row doesn't carry
/// visual noise at rest.
private struct AppBindingRow: View {
    let bundleID: String
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "questionmark.app")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
            Text(displayName)
                .lineLimit(1)
            Spacer()
            if hovering {
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .help(bundleID)
        .onHover { hovering = $0 }
    }

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var appIcon: NSImage? {
        guard let url = appURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var displayName: String {
        guard let url = appURL else { return bundleID }
        // FileManager.displayName strips the .app extension; if the app's been
        // uninstalled since the binding was created, fall back to the id so
        // the user can still recognise what they bound.
        return FileManager.default.displayName(atPath: url.path)
    }
}
