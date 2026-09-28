import SwiftUI
import AppKit

// The menu-bar popover's building blocks: the row button style, the Mode
// section and the Recent section. `MenuBarContent` lays them out.

// MARK: - Row style

/// What every clickable row in the popover looks like: flush with the section
/// headers at rest, a rounded highlight under the pointer.
///
/// The popover is a `.window`-style `MenuBarExtra`, so none of this comes for
/// free — its rows were `.plain` buttons, which is why nothing reacted to the
/// mouse and the menu read as a block of text rather than things to click.
/// The highlight is a neutral wash, not the accent-coloured selection of a
/// real `NSMenu`: this popover sits on the same material as Control Center,
/// and that's the idiom there.
struct MenuRowStyle: ButtonStyle {
    /// Keep the highlight on while something the row owns is open (the
    /// versions popover), the way a menu item stays lit while its submenu is.
    var highlighted = false
    /// Full-width rows stretch to the popover's edges; footer buttons sit side
    /// by side and only take their own width.
    var fillsWidth = true

    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration, highlighted: highlighted, fillsWidth: fillsWidth)
    }
}

private struct MenuRowBody: View {
    let configuration: ButtonStyleConfiguration
    let highlighted: Bool
    let fillsWidth: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
            )
            .contentShape(Rectangle())
            // Pull the padding back out so the row's text lines up with the
            // section headers and only the highlight reaches into the margin —
            // the same geometry as a native menu item.
            .padding(.horizontal, -6)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Color.primary.opacity(0.16) }
        if hovering || highlighted { return Color.primary.opacity(0.09) }
        return .clear
    }
}

/// Small uppercase section label, shared by every section in the popover.
struct MenuSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Mode

/// The default mode, and — for the app you were just in — which mode
/// dictating there actually uses.
///
/// "The app you were just in" is `ChatInsertion.target`: by the time this
/// popover is open Dictator is frontmost, so `frontmostApplication` would
/// answer "Dictator". ChatInsertion already tracks the last app that *wasn't*
/// us for exactly this reason.
///
/// The app row is both the indicator and the control. Its picker reads
/// "Default (…)" or the app's own mode — the override that used to be
/// invisible outside Settings — and the Default row dims while that override
/// is in charge. Picking a mode from it writes the same
/// `appBundleIDs` binding the mode editor does — so it sticks, and the mode
/// editor shows it afterwards.
struct MenuModeSection: View {
    @Environment(AppState.self) private var state
    @State private var insertion = ChatInsertion.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader(title: "Mode")

            HStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Default")
                    .font(.system(size: 13, design: .rounded))
                    // Dimmed while the app row's own mode is the one that
                    // applies: which row is in charge reads off the rows
                    // themselves, without a sentence explaining it.
                    .foregroundStyle(appOverridesDefault ? .secondary : .primary)
                Spacer(minLength: 8)
                Picker("Default mode", selection: defaultBinding) {
                    ForEach(state.settings.modes) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if let app = targetApp, let bundleID = app.bundleIdentifier {
                appRow(app: app, bundleID: bundleID)
            }
        }
    }

    /// The last app that wasn't Dictator, if it's still running. Hidden in
    /// screenshot runs, which would otherwise print whatever the person
    /// running them had open.
    private var targetApp: NSRunningApplication? {
        guard !ScreenshotMode.isActive,
              let app = insertion.target, !app.isTerminated,
              app.bundleIdentifier != nil
        else { return nil }
        return app
    }

    @ViewBuilder
    private func appRow(app: NSRunningApplication, bundleID: String) -> some View {
        let name = app.localizedName ?? bundleID
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app")
                    }
                }
                .frame(width: 16, height: 16)
                Text("In \(name)")
                    .font(.system(size: 13, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Picker("Mode in \(name)", selection: overrideBinding(bundleID: bundleID)) {
                    Text("Default (\(state.settings.defaultMode.name))").tag(UUID?.none)
                    Divider()
                    ForEach(state.settings.modes) { mode in
                        Text(mode.name).tag(UUID?.some(mode.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            // A website binding beats an app binding, and working out whether
            // one applies means walking the browser's accessibility tree —
            // not something to do every time this popover opens. Say so
            // rather than show an answer that might be wrong.
            if BrowserURLReader.isBrowser(bundleID: bundleID), state.settings.anyModeHasURLBinding {
                Text("Website rules still take over on the sites they match.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
        }
    }

    /// True when dictating in the target app would use its own mode rather
    /// than the default.
    private var appOverridesDefault: Bool {
        guard let bundleID = targetApp?.bundleIdentifier,
              let bound = boundMode(for: bundleID)
        else { return false }
        return bound.id != state.settings.defaultModeID
    }

    /// Mirrors `DictatorSettings.activeMode`'s app tier: first mode in list
    /// order whose bindings contain the bundle ID.
    private func boundMode(for bundleID: String) -> DictationMode? {
        state.settings.modes.first { $0.appBundleIDs.contains(bundleID) }
    }

    private var defaultBinding: Binding<UUID> {
        Binding(
            get: { state.settings.defaultMode.id },
            set: { id in
                state.settings.defaultModeID = id
                state.save()
            }
        )
    }

    /// nil = "use the default". Setting a mode removes the app from every
    /// other mode first: resolution is first-match, so a second binding would
    /// either be dead weight or — after a reorder — silently win.
    private func overrideBinding(bundleID: String) -> Binding<UUID?> {
        Binding(
            get: { boundMode(for: bundleID)?.id },
            set: { id in
                for i in state.settings.modes.indices {
                    state.settings.modes[i].appBundleIDs.removeAll { $0 == bundleID }
                }
                if let id, let i = state.settings.modes.firstIndex(where: { $0.id == id }) {
                    state.settings.modes[i].appBundleIDs.append(bundleID)
                }
                state.save()
            }
        )
    }
}

// MARK: - Recent

/// The last few dictations: what came out, which stages it went through, and
/// — on hover — every version along the way, each one copyable.
///
/// The stage trail on each row is the "is dictation actually working?"
/// glance: a Clean mode that only ever shows "Transcript" is a mode whose passes are
/// failing, and the note line says why when the pipeline recorded a reason.
struct MenuRecentSection: View {
    let records: [DictationRecord]

    @State private var justCopied: UUID?
    /// The row whose versions popover is open.
    @State private var shownID: UUID?
    /// The row under the pointer right now.
    @State private var hoverRowID: UUID?
    @State private var overPopover = false
    @State private var openTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                MenuSectionHeader(title: "Recent")
                Spacer()
                Button("History…") { Self.openHistory() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(records) { record in
                    let hasVersions = record.versions.count > 1
                    Button {
                        copy(record.final, id: record.id)
                    } label: {
                        RecentRow(record: record, copied: justCopied == record.id, hasVersions: hasVersions)
                    }
                    .buttonStyle(MenuRowStyle(highlighted: shownID == record.id))
                    .onHover { rowHover(record.id, inside: $0, hasVersions: hasVersions) }
                    .popover(isPresented: presented(record.id), arrowEdge: .leading) {
                        VersionsPopover(record: record)
                            .onHover { inside in
                                overPopover = inside
                                if !inside { scheduleClose() }
                            }
                    }
                }
            }
        }
    }

    static func openHistory() {
        let settings = SettingsWindowController.shared
        settings.model.section = .dictation
        settings.model.dictationTab = .history
        settings.show()
    }

    private func copy(_ text: String, id: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            if justCopied == id { justCopied = nil }
        }
    }

    private func presented(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { shownID == id },
            set: { if !$0, shownID == id { shownID = nil } }
        )
    }

    // Submenu timing, borrowed from NSMenu: a short dwell before the first one
    // opens (so sweeping the pointer across the list doesn't flash popovers),
    // then near-instant switching once one is open, and a grace period on the
    // way out so the pointer can travel from the row into the popover.

    private func rowHover(_ id: UUID, inside: Bool, hasVersions: Bool) {
        if inside {
            hoverRowID = id
            openTask?.cancel()
            guard hasVersions else {
                scheduleClose()
                return
            }
            guard shownID != id else { return }
            let delay = shownID == nil ? 450 : 120
            openTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, hoverRowID == id else { return }
                shownID = id
            }
        } else {
            if hoverRowID == id { hoverRowID = nil }
            scheduleClose()
        }
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !overPopover, hoverRowID != shownID else { return }
            shownID = nil
        }
    }
}

private struct RecentRow: View {
    let record: DictationRecord
    let copied: Bool
    let hasVersions: Bool

    private var isJournal: Bool { record.deliveredToJournal ?? false }

    private var rowIcon: String {
        if copied { return "checkmark.circle.fill" }
        return isJournal ? "book.closed.fill" : "mic.fill"
    }

    private var rowTint: Color {
        if copied { return .green }
        if isJournal { return CaptureKind.journal.tint }
        return record.pasted ? .secondary : .orange
    }

    /// "Transcript › Clean › Paragraphs" — the stages this dictation went through,
    /// short enough for one line.
    private var trail: String {
        record.versions
            .map(\.name)
            .map { name in
                switch name {
                case "Dictionary-corrected": "Dictionary"
                case DictationRecord.adjustedStageName: "Adjusted"
                default: name
                }
            }
            .joined(separator: " › ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // The glyph says which flow produced the row — a mic for dictation,
            // the journal's book for a journal entry — rather than what
            // happened to the clipboard, which is the less interesting half.
            // Colour still carries delivery: normal when it went into the app,
            // orange when it only reached the clipboard. A filed journal entry
            // takes the journal tint — it was never going to be pasted, so the
            // warning colour it used to get was misreporting a success. A
            // journal write that *failed* has `deliveredToJournal` false and so
            // still shows orange, which is exactly what happened to it.
            Image(systemName: rowIcon)
                .foregroundStyle(rowTint)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.final)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Text(copied ? "Copied" : Self.relative(record.timestamp))
                        .monospacedDigit()
                    Text("·")
                    Text(trail)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                if let note = record.note, !note.isEmpty {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            // The submenu arrow: hovering this row opens its versions.
            if hasVersions {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 1)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Every version of one dictation, oldest first, each a click to copy. The
/// point is recovery: if Polished rewrote something it shouldn't have, the
/// Clean or raw text is one click away instead of a trip to Settings.
private struct VersionsPopover: View {
    let record: DictationRecord
    @State private var copiedIndex: Int?

    var body: some View {
        // Short lists size to their content; long ones scroll inside a cap.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(width: 330)
        .frame(maxHeight: 460)
    }

    private var content: some View {
        let versions = record.versions
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                MenuSectionHeader(title: "Versions")
                Spacer()
                Text("Click to copy")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)
            ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                if index > 0 { Divider() }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(version.text, forType: .string)
                    copiedIndex = index
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(900))
                        if copiedIndex == index { copiedIndex = nil }
                    }
                } label: {
                    versionLabel(version, delivered: index == versions.count - 1, copied: copiedIndex == index)
                }
                .buttonStyle(MenuRowStyle())
            }
        }
        .padding(12)
    }

    private func versionLabel(_ version: DictationStage, delivered: Bool, copied: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(version.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if delivered {
                    Text(record.deliveredToJournal == true ? "Journal" : record.pasted ? "Pasted" : "Copied")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            if version.name == DictationRecord.adjustedStageName {
                Text("Spacing, casing or punctuation changed to fit where it landed.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Text(version.text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
