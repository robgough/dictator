import AppKit
import SwiftUI

/// Multi-turn result window for Assistant Mode. Reads its content from
/// `ConversationHistory.shared` by id, so updates from Pipeline propagate
/// automatically via @Observable. While the window is open, the next
/// assistant hotkey continues the displayed conversation; closing the
/// window (X, Done button, or programmatic close) ends the conversation —
/// the next call starts fresh. After a REPLACE turn the window never
/// opens; in that case, continuation falls back to selection-overlap with
/// the previous reply (Pipeline.shouldContinueConversation).
@MainActor
final class AssistantResultController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var displayedConversationID: UUID?

    /// Called when the user closes the window (X or Done). AppState wires
    /// this to `pipeline.endActiveConversation()` so the next assistant
    /// call starts fresh.
    var onWindowClosed: (() -> Void)?

    /// Called when the user reopens a conversation from the menu bar so the
    /// pipeline can switch its active conversation to match what's on screen.
    var onConversationDisplayed: ((UUID) -> Void)?

    /// True while the window is on-screen. Pipeline asks this when deciding
    /// whether the next assistant call is a continuation.
    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Conversation id currently displayed *and* visible. Used by Pipeline's
    /// continuation check. Returns nil when the window is hidden so a closed
    /// window doesn't lock the next call into the wrong conversation.
    var currentConversationID: UUID? {
        guard isWindowVisible else { return nil }
        return displayedConversationID
    }

    /// Update the window to show a given conversation. `surface` true brings
    /// it to the front (DRAFT mode, paste-fallback, or menu-bar reopen).
    /// `surface` false only re-renders if the window is already visible —
    /// used for REPLACE turns that happen while the user is following along.
    func showConversation(id: UUID, surface: Bool) {
        displayedConversationID = id
        let alreadyVisible = window?.isVisible ?? false
        guard surface || alreadyVisible else { return }

        let window = ensureWindow()
        let root = AssistantResultView(
            conversationID: id,
            onCopy: { [weak self] text in self?.copyToClipboard(text) },
            onClose: { [weak self] in self?.requestClose() }
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Assistant"
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        onConversationDisplayed?(id)
    }

    /// Programmatic close, used by the Done button. Routes through the
    /// window's close path so the NSWindowDelegate hook fires uniformly
    /// regardless of whether the user closed via the title bar or the
    /// button.
    private func requestClose() {
        window?.performClose(nil)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.minSize = NSSize(width: 560, height: 400)
        w.delegate = self
        window = w
        return w
    }

    // MARK: - NSWindowDelegate

    /// Fired for both the title-bar X and `performClose`. Clears active
    /// conversation in the pipeline so the next hotkey press starts fresh.
    /// `windowWillClose` doesn't fire on plain `orderOut`, so this is
    /// specifically the user-initiated close path.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            displayedConversationID = nil
            onWindowClosed?()
        }
    }
}

private struct AssistantResultView: View {
    let conversationID: UUID
    let onCopy: (String) -> Void
    let onClose: () -> Void

    @State private var history = ConversationHistory.shared
    @State private var copyFeedback = false

    private var conversation: Conversation? {
        history.conversation(id: conversationID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let conversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let comp = conversation.compaction {
                                CompactionNote(summary: comp.summary)
                            }
                            ForEach(Array(visibleTurns(in: conversation).enumerated()), id: \.element.id) { _, turn in
                                TurnRow(turn: turn)
                                    .id(turn.id)
                            }
                        }
                        .padding(14)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .onChange(of: conversation.turns.last?.id) { _, newID in
                        if let newID {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let lastID = conversation.turns.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                if let engine = AppState.shared.settings.activeLLMEngine(),
                   conversation.isApproachingContextLimit(engine: engine) {
                    ApproachingLimitChip()
                }
                footer(conversation: conversation)
            } else {
                Text("Conversation no longer available.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 400)
    }

    @ViewBuilder
    private var header: some View {
        if let conversation {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.indigo)
                    .font(.system(size: 13, weight: .semibold))
                Text(turnCountLabel(conversation))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Press the assistant hotkey again to continue")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func turnCountLabel(_ c: Conversation) -> String {
        c.turns.count == 1 ? "1 turn" : "\(c.turns.count) turns"
    }

    @ViewBuilder
    private func footer(conversation: Conversation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text("Latest reply is on your clipboard — \u{2318}V to paste anywhere. Closing ends this conversation.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if let last = conversation.turns.last {
                Button(copyFeedback ? "Copied" : "Copy latest") {
                    onCopy(last.reply)
                    copyFeedback = true
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        copyFeedback = false
                    }
                }
            }
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
            // Hidden twin so Escape also closes the window. SwiftUI Buttons
            // can only carry one keyboardShortcut each, hence the pair.
            Button("", action: onClose)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// The window shows every turn — including ones that have been compacted
    /// away from the LLM payload. The user told us to keep what's on screen
    /// honest: "we want it to be clear what has gone on throughout the
    /// conversation". The CompactionNote at the top signals that older turns
    /// no longer count toward the model's context.
    private func visibleTurns(in c: Conversation) -> [ConversationTurn] {
        c.turns
    }
}

private struct TurnRow: View {
    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.indigo)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text("\u{201C}\(turn.instruction)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let selection = turn.selection, !selection.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "selection.pin.in.out")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14)
                    Text(selection)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(turn.reply)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
        }
        .padding(.vertical, 4)
    }
}

private struct CompactionNote: View {
    let summary: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                Text("Earlier turns summarised to fit context")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(expanded ? "Hide summary" : "Show summary") {
                    expanded.toggle()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            if expanded {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct ApproachingLimitChip: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11, weight: .semibold))
            Text("Approaching context limit — older turns will be summarised next")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.12))
        )
    }
}
