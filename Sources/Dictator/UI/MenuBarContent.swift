import SwiftUI
import AppKit
import AVFoundation
import KeyboardShortcuts

struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @State private var history = DictationHistory.shared
    @State private var conversations = ConversationHistory.shared
    @State private var modelManager = ModelManager.shared
    @State private var justCopied: UUID?
    private let demo = DemoMode.shared

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 10) {
            if demo.isOn { demoBanner }
            header
            Divider()
            statusRow

            // Default mode picker — only shown once the user has more than the
            // built-in Quick (i.e. after migration or once they add a custom
            // mode). One mode = nothing to pick between.
            if state.settings.modes.count > 1 {
                Divider()
                modePicker(bindable: $s)
            }

            if !demo.conversations(real: conversations.conversations).isEmpty {
                Divider()
                conversationsList
            }

            if !demo.historyIsEmpty(real: history.records) {
                Divider()
                recentList
            }

            // Its own full-width row, and only when the app is actually
            // installed: squeezed into the footer next to Settings and Quit
            // the label wrapped, and users without Dictator Meetings have no
            // use for it at all.
            if meetingsInstalled {
                Divider()
                Button {
                    openDictatorMeetings()
                } label: {
                    Label("Open Dictator Meetings…", systemImage: "person.2.wave.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .rounded))
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                // The wizard exists to walk you through the things that
                // *must* be configured for dictation to work. Once mic is
                // granted and at least one model in the active engine is
                // installed, there's nothing left to set up — hide the
                // entry so it stops cluttering the menu.
                if needsSetup {
                    Button {
                        state.showOnboarding()
                    } label: {
                        Label("Setup…", systemImage: "sparkles")
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            // Recompute on-disk model state each time the menu opens — the
            // user may have downloaded or removed a model from Settings
            // since we last refreshed.
            modelManager.refreshCachedStates()
        }
    }

    /// Launch the separate Dictator Meetings app, or — when it isn't
    /// installed — send the user to the download page.
    ///
    /// `urlForApplication(withBundleIdentifier:)` is the only reliable way to
    /// find it: it may be in `/Applications`, `~/Applications`, or a
    /// DerivedData folder on a development Mac, and Launch Services already
    /// knows which. Launching by URL (rather than
    /// `launchApplication(withBundleIdentifier:)`) keeps the "already running"
    /// case a plain re-activation.
    private static let meetingsBundleID = "net.robgough.DictatorMeetings"

    /// Whether Dictator Meetings is installed anywhere Launch Services knows
    /// about. Evaluated on each popover render — cheap, and it means the row
    /// appears the moment the app is installed without a relaunch.
    private var meetingsInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.meetingsBundleID) != nil
    }

    private func openDictatorMeetings() {
        let bundleID = Self.meetingsBundleID
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            if let site = URL(string: "https://dictator.robgough.net/#meetings") {
                NSWorkspace.shared.open(site)
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                NSLog("[Dictator] Couldn't launch Dictator Meetings: \(error)")
            }
        }
    }

    /// True when the wizard still has something to do for the user.
    /// Mic must be authorized AND at least one model in the active
    /// transcription engine must be installed. Accessibility is optional
    /// (clipboard fallback works), and the LLM is optional too — neither
    /// blocks dictation.
    private var needsSetup: Bool {
        if MicPermission.status() != .authorized { return true }
        switch state.settings.transcriptionEngine {
        case .parakeet:
            return !ModelCatalog.parakeetModels.contains { modelManager.parakeetStates[$0.id] == .ready }
        case .whisper:
            return !ModelCatalog.whisperModels.contains { modelManager.whisperStates[$0.id] == .ready }
        }
    }

    /// Inline mode picker. Renders the user's modes as a horizontal pill row
    /// rather than a Menu picker — fewer clicks, and the selected mode is
    /// always visible in the menu bar without expanding anything.
    @ViewBuilder
    private func modePicker(bindable s: Bindable<AppState>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default mode")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            // WrapLayout wraps chips onto a second row when the popover
            // can't fit them all horizontally. Previously a plain HStack
            // squeezed each pill below its natural width, which made
            // SwiftUI break the labels mid-word ("Writ\ne", "Mess\nages")
            // as soon as the user added a longer mode name.
            WrapLayout(spacing: 6, lineSpacing: 6) {
                ForEach(state.settings.modes) { mode in
                    Button {
                        state.settings.defaultModeID = mode.id
                        state.save()
                    } label: {
                        Text(mode.name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            // fixedSize on the label so each pill sizes
                            // to its own natural width — WrapLayout only
                            // wraps to a new row, it doesn't shrink the
                            // children. Without this, very long mode
                            // names that exceed the popover width would
                            // still truncate; the alternative (let them
                            // truncate with `…`) reads worse than a
                            // slightly-wider-than-popover pill.
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            // Selected = solid accent with white text; a tinted
                            // capsule with accent text failed contrast on the
                            // light-mode popover material.
                            .background(
                                Capsule().fill(
                                    state.settings.defaultModeID == mode.id
                                    ? Color.brandBlue
                                    : Color.primary.opacity(0.08)
                                )
                            )
                            .foregroundStyle(
                                state.settings.defaultModeID == mode.id
                                ? Color.white
                                : Color.primary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        Text("Recent")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

        VStack(alignment: .leading, spacing: 2) {
            ForEach(demo.history(real: history.records).prefix(5)) { record in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.final, forType: .string)
                    justCopied = record.id
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(800))
                        if justCopied == record.id { justCopied = nil }
                    }
                } label: {
                    RecentRow(record: record, copied: justCopied == record.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The one place demo mode is visible as itself: a small pill at the top of
    /// the dropdown, with a way out. Everything else in the UI looks exactly as
    /// it normally does, so a recording doesn't advertise that it's staged.
    private var demoBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Demo")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("showing fictional content")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Turn off") { demo.setOn(false) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictator")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                VStack(alignment: .leading, spacing: 1) {
                    HotkeyHint(
                        label: "Dictate",
                        keys: Self.hotkeyDisplay(name: .toggleDictation, mode: state.settings.triggerMode)
                    )
                    HotkeyHint(
                        label: "Assistant",
                        keys: Self.hotkeyDisplay(name: .toggleAssistant, mode: state.settings.assistantTriggerMode)
                    )
                }
            }
            Spacer()
        }
    }

    /// Compact human-readable form of a hotkey for the menu-bar header.
    /// For keyboard combinations we ask KeyboardShortcuts for the current
    /// `Shortcut`'s description (e.g. "⌥⌘D"). For modifier-only triggers we
    /// render side + symbol (e.g. "Right ⌥") since the binder distinguishes
    /// left/right by virtual key code.
    private static func hotkeyDisplay(name: KeyboardShortcuts.Name, mode: TriggerMode) -> String {
        switch mode {
        case .keyboardShortcut:
            return KeyboardShortcuts.getShortcut(for: name)?.description ?? "Not set"
        case .leftOption:    return "Left ⌥"
        case .rightOption:   return "Right ⌥"
        case .leftCommand:   return "Left ⌘"
        case .rightCommand:  return "Right ⌘"
        case .leftControl:   return "Left ⌃"
        case .rightControl:  return "Right ⌃"
        case .leftShift:     return "Left ⇧"
        case .rightShift:    return "Right ⇧"
        case .fn:            return "fn"
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: state.pipeline.state.iconName)
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            if state.pipeline.state.isActive {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch state.pipeline.state {
        case .idle: "Idle"
        case .capturingSelection: "Reading selection…"
        case .warmingUp: "Connecting microphone…"
        case .recording(_, let kind, _):
            switch kind {
            case .dictation: "Listening…"
            case .assistant: "Listening for instruction…"
            case .journal:   "Listening for your journal…"
            }
        case .transcribing: "Transcribing…"
        case .readingScreen: "Reading screen…"
        case .formatting: "Formatting…"
        case .fixingGrammar: "Polishing…"
        case .restructuring: "Paragraphs…"
        case .translating: "Translating…"
        case .assisting: "Thinking…"
        case .compacting: "Summarising earlier turns…"
        case .done(_, let pasted, _):
            if state.pipeline.lastDeliveryWasJournal { "Saved to your journal" }
            else { pasted ? "Pasted" : "Copied to clipboard" }
        case .failed(let m): m
        }
    }

    @ViewBuilder
    private var conversationsList: some View {
        HStack {
            Text("Conversations")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if demo.conversations(real: conversations.conversations).count > 1 {
                Button("Clear all") {
                    demo.clearConversations { conversations.clear() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            ForEach(demo.conversations(real: conversations.conversations).prefix(5)) { convo in
                ConversationRow(
                    conversation: convo,
                    onOpen: { state.openConversation(id: convo.id) },
                    onDelete: { demo.removeConversation(id: convo.id) { conversations.remove(id: convo.id) } }
                )
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.indigo)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 4) {
                        Text("\(conversation.turns.count) turn\(conversation.turns.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(Self.relative(conversation.updatedAt))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct RecentRow: View {
    let record: DictationRecord
    let copied: Bool

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

            VStack(alignment: .leading, spacing: 1) {
                Text(record.final)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Text(Self.relative(record.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(copied ? Color.green.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// A simple left-aligned flow layout that places each subview at its
/// intrinsic size and wraps onto a new row whenever the next subview
/// would exceed the proposed width. Used by the menu-bar mode picker so
/// adding a long mode name pushes chips to a second row instead of
/// squashing all the chips below their natural width (which made
/// SwiftUI break the labels mid-word).
private struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for entry in row.entries {
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(entry.size)
                )
                x += entry.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var entries: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let projected = current.entries.isEmpty ? size.width : current.width + spacing + size.width
            if !current.entries.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.entries.append((i, size))
            current.width = current.entries.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.entries.isEmpty { rows.append(current) }
        return rows
    }
}

private struct HotkeyHint: View {
    let label: String
    let keys: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
    }
}
