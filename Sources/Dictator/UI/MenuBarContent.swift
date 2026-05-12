import SwiftUI
import AppKit
import KeyboardShortcuts
import Sparkle

struct MenuBarContent: View {
    let updater: SPUUpdater

    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @State private var history = DictationHistory.shared
    @State private var conversations = ConversationHistory.shared
    @State private var justCopied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRow

            if !conversations.conversations.isEmpty {
                Divider()
                conversationsList
            }

            if !history.records.isEmpty {
                Divider()
                recentList
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Spacer()
                CheckForUpdatesButton(updater: updater)
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
    }

    @ViewBuilder
    private var recentList: some View {
        Text("Recent")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

        VStack(alignment: .leading, spacing: 2) {
            ForEach(history.mostRecent(10)) { record in
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
        case .recording(_, let isAssistant): isAssistant ? "Listening for instruction…" : "Listening…"
        case .transcribing: "Transcribing…"
        case .formatting: "Formatting…"
        case .fixingGrammar: "Tidying grammar…"
        case .restructuring: "Structuring…"
        case .assisting: "Thinking…"
        case .compacting: "Summarising earlier turns…"
        case .done(_, let pasted, _): pasted ? "Pasted" : "Copied to clipboard"
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
            if conversations.conversations.count > 1 {
                Button("Clear all") {
                    conversations.clear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            ForEach(conversations.mostRecent(5)) { convo in
                ConversationRow(
                    conversation: convo,
                    onOpen: { state.openConversation(id: convo.id) },
                    onDelete: { conversations.remove(id: convo.id) }
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: copied ? "checkmark.circle.fill" : (record.pasted ? "doc.on.doc" : "doc.on.clipboard"))
                .foregroundStyle(copied ? .green : (record.pasted ? .secondary : .orange))
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

/// "Check for Updates…" entry that mirrors Sparkle's `canCheckForUpdates`
/// state so the button greys out while a check is in flight.
private struct CheckForUpdatesButton: View {
    let updater: SPUUpdater

    @State private var canCheck = true

    var body: some View {
        Button {
            updater.checkForUpdates()
        } label: {
            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!canCheck)
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
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
