import SwiftUI
import AppKit
import Combine
import KeyboardShortcuts

/// Sub-divisions inside the Dictation section — the old Input, Modes and
/// History sidebar entries, folded behind the toolbar's segmented control.
///
/// Internal, not private: `SettingsShellModel` holds the selection and the
/// toolbar fragment in SettingsShell.swift renders the cases.
enum DictationSubPane: String, CaseIterable, Identifiable {
    case modes = "Modes"
    case microphone = "Microphone"
    case history = "History"
    var id: String { rawValue }
}

/// Host for the three Dictation sub-panes. The segmented control lives in the
/// window toolbar (SettingsShell) and drives `shell.dictationTab`; the "+" and
/// Clear toolbar buttons appear only on the tab that owns them.
struct DictationPane: View {
    @Bindable var shell: SettingsShellModel

    var body: some View {
        switch shell.dictationTab {
        case .modes:      DictationModesTab(shell: shell)
        case .microphone: MicrophonePane().settingsDetailPadding()
        case .history:    HistoryPane(shell: shell)
        }
    }
}

/// Modes tab: the dictation hotkey, the default-mode picker, and the ordered
/// list of modes. Clicking a row opens `ModeEditorSheet`.
private struct DictationModesTab: View {
    @Environment(AppState.self) private var state
    @Bindable var shell: SettingsShellModel

    /// `List(selection:)` + `.onMove` (not Button rows): the List coordinates
    /// click-to-select with press-drag-to-reorder, and a tap gesture on a row
    /// eats the drag. Selection is what opens the editor sheet; it's cleared
    /// when the sheet dismisses so re-clicking the same mode re-opens it.
    @State private var selectedID: UUID?
    @State private var confirmResetModes = false

    /// Tab cycling needs Accessibility (the event tap has to swallow the Tab
    /// keystroke before it inserts a tab character). Without it the footer
    /// says so instead of explaining the ordering.
    @State private var axGranted: Bool = TextInjector.hasAccessibilityPermission()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        @Bindable var s = state
        Form {
            Section {
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
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleDictation)
                        Button("Reset") {
                            state.resetDictationKeyboardShortcut()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Hotkey")
            } footer: {
                SectionFootnote("Hold to record, release to transcribe.")
            }

            Section {
                Picker("Default mode", selection: Binding(
                    get: { state.settings.defaultModeID },
                    set: { newValue in
                        state.settings.defaultModeID = newValue
                        state.save()
                    }
                )) {
                    ForEach(state.settings.modes) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                .pickerStyle(.menu)

                modeList

                HStack {
                    Spacer()
                    Button("Reset to defaults…", role: .destructive) {
                        confirmResetModes = true
                    }
                    .controlSize(.small)
                }
                .confirmationDialog(
                    "Reset modes to defaults?",
                    isPresented: $confirmResetModes,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) { resetModesToDefaults() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Replaces every mode with the built-in set: Quick, Standard, Polished and Messages. Custom prompts and app bindings are lost.")
                }
            } header: {
                Text("Modes")
            } footer: {
                SectionFootnote(axGranted
                                ? "Drag to reorder — Tab cycles modes in this order while recording."
                                : "Tab cycling needs Accessibility (see General).")
            }
        }
        .formStyle(.grouped)
        .onReceive(pollTimer) { _ in
            axGranted = TextInjector.hasAccessibilityPermission()
        }
        .onChange(of: selectedID) { _, new in
            if let new { shell.modeEditorID = new }
        }
        .onChange(of: shell.modeEditorID) { _, new in
            if new == nil { selectedID = nil }
        }
        // Belt-and-braces: if the mode being edited disappears out from under
        // the sheet (deleted via the context menu), dismiss rather than leave
        // a blank sheet stuck open — the `if let idx` below already prevents
        // a crash, but doesn't get the sheet to close on its own.
        .onChange(of: state.settings.modes) { _, modes in
            if let id = shell.modeEditorID, !modes.contains(where: { $0.id == id }) {
                shell.modeEditorID = nil
            }
        }
        .sheet(item: editorTarget) { target in
            if let idx = state.settings.modes.firstIndex(where: { $0.id == target.id }) {
                ModeEditorSheet(
                    mode: $s.settings.modes[idx],
                    isDefault: state.settings.defaultModeID == target.id,
                    onMakeDefault: {
                        state.settings.defaultModeID = target.id
                        state.save()
                    },
                    onChange: { state.save() }
                )
            }
        }
        .sheet(isPresented: $shell.showAddModeSheet) {
            AddModeSheet { template in
                installMode(from: template)
            }
        }
    }

    /// `.sheet(item:)` needs an `Identifiable`; the shell keeps the plain
    /// `UUID?` the toolbar and pane both reason about.
    private var editorTarget: Binding<ModeEditorTarget?> {
        Binding(
            get: { shell.modeEditorID.map(ModeEditorTarget.init(id:)) },
            set: { shell.modeEditorID = $0?.id }
        )
    }

    /// Sized to its content: a `List` inside a grouped `Form` section would
    /// otherwise take an arbitrary height and nest a second scroller inside
    /// the form's own. Capped so a long mode list still scrolls internally
    /// rather than pushing the footer off-screen.
    /// Fixed row height — title (14pt semibold) + 4pt + caption (11pt) with
    /// breathing room. The list is sized from it exactly (plus the plain
    /// style's own 4pt top/bottom inset), and scrolls only past
    /// `maxVisibleModeRows`.
    static let modeRowHeight: CGFloat = 50
    static let maxVisibleModeRows = 8

    private var listHeight: CGFloat {
        let rows = min(state.settings.modes.count, Self.maxVisibleModeRows)
        return CGFloat(rows) * Self.modeRowHeight + 8
    }

    private var modeList: some View {
        List(selection: $selectedID) {
            ForEach(state.settings.modes) { mode in
                ModeCard(mode: mode, isDefault: state.settings.defaultModeID == mode.id)
                    // Every row is exactly `modeRowHeight` tall so the list's
                    // frame below is arithmetic, not a guess: a guessed 46pt
                    // clipped the last row's subtitle and left the slack as
                    // a gap above the first.
                    .frame(height: Self.modeRowHeight)
                    .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                    .listRowSeparator(.visible)
                    .tag(mode.id)
                    .contextMenu {
                        if state.settings.defaultModeID != mode.id {
                            Button("Make Default") { makeDefault(mode) }
                        }
                        Button("Duplicate") { duplicateMode(mode) }
                        if canDelete(mode) {
                            Divider()
                            Button("Delete", role: .destructive) { deleteMode(mode) }
                        }
                    }
            }
            .onMove { offsets, destination in
                state.settings.modes.move(fromOffsets: offsets, toOffset: destination)
                state.save()
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, Self.modeRowHeight)
        .scrollContentBackground(.hidden)
        .scrollDisabled(state.settings.modes.count <= Self.maxVisibleModeRows)
        .frame(height: listHeight)
    }

    // MARK: - Actions

    private func canDelete(_ mode: DictationMode) -> Bool {
        // Don't let the list collapse to empty, and Quick is locked.
        !mode.isLocked && state.settings.modes.count > 1
    }

    private func makeDefault(_ mode: DictationMode) {
        state.settings.defaultModeID = mode.id
        state.save()
    }

    /// Back to a fresh install's modes. Useful for seeing what other users see,
    /// and the escape hatch when a migration or an experiment leaves the list
    /// in a state that's easier to discard than repair.
    private func resetModesToDefaults() {
        shell.modeEditorID = nil
        state.settings.modes = DictatorSettings.defaults.modes
        state.settings.defaultModeID = DictatorSettings.defaults.defaultModeID
        state.save()
    }

    /// Installs a fresh mode from a gallery template: a fresh id (so a starter
    /// can be added several times), a unique name, unlocked, no app bindings.
    /// Opens the editor on it.
    private func installMode(from template: DictationMode) {
        var copy = template
        copy.id = UUID()
        copy.name = uniqueName(from: template.name)
        copy.isLocked = false
        copy.includeInCycle = true
        copy.appBundleIDs = []
        state.settings.modes.append(copy)
        state.save()
        shell.modeEditorID = copy.id
    }

    /// A name that doesn't collide with an existing mode — starters keep their
    /// clean name on first add ("Polished"), then get "Polished 2", etc.
    private func uniqueName(from base: String) -> String {
        let existing = Set(state.settings.modes.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func duplicateMode(_ mode: DictationMode) {
        var copy = mode
        copy.id = UUID()
        copy.name = uniqueName(basedOn: mode.name)
        copy.isLocked = false
        copy.appBundleIDs = []  // Don't double-claim apps
        if let idx = state.settings.modes.firstIndex(where: { $0.id == mode.id }) {
            state.settings.modes.insert(copy, at: idx + 1)
        } else {
            state.settings.modes.append(copy)
        }
        state.save()
    }

    private func deleteMode(_ mode: DictationMode) {
        guard canDelete(mode) else { return }
        let wasDefault = state.settings.defaultModeID == mode.id
        state.settings.modes.removeAll(where: { $0.id == mode.id })
        if wasDefault {
            // Re-point default to whatever's at the top of the list — usually
            // Quick, since it's seeded first.
            state.settings.defaultModeID = state.settings.modes.first?.id ?? DictationMode.quickID
        }
        state.save()
    }

    /// Returns "Name copy" / "Name copy 2" / ... so duplicates don't share a
    /// label and become indistinguishable in the list.
    private func uniqueName(basedOn name: String) -> String {
        let existing = Set(state.settings.modes.map(\.name))
        let base = name.hasSuffix(" copy") ? name : "\(name) copy"
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// A mode in the list: name + badges, plus a one-line summary of what the mode
/// does and how it activates. Click opens `ModeEditorSheet`.
private struct ModeCard: View {
    let mode: DictationMode
    let isDefault: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if mode.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(mode.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if isDefault {
                    Text("default")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Clean · 2 apps · Tab cycle" — the style, and how the mode is reached,
    /// so the list is informative without opening the editor.
    private var summary: String {
        var s = mode.style.label
        var extras: [String] = []
        if !mode.appBundleIDs.isEmpty {
            extras.append("\(mode.appBundleIDs.count) app\(mode.appBundleIDs.count == 1 ? "" : "s")")
        }
        if mode.includeInCycle { extras.append("Tab cycle") }
        if !extras.isEmpty { s += "  ·  " + extras.joined(separator: " · ") }
        return s
    }
}

/// The "+" gallery: one card per `DictationStyle` (`DictationMode.galleryTemplates`).
/// Passes the chosen template back to the modes tab, which clones it with a
/// fresh id and opens the editor on it.
private struct AddModeSheet: View {
    let onPick: (DictationMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a mode").font(.title2.weight(.bold))
            VStack(spacing: 8) {
                ForEach(Array(DictationMode.galleryTemplates.enumerated()), id: \.offset) { _, template in
                    starterCard(template)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func starterCard(_ mode: DictationMode) -> some View {
        Button {
            onPick(mode)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.style.label).font(.headline)
                    Text(mode.style.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
