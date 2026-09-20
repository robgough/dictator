import AppKit
import SwiftUI

/// Multi-turn result window for Assistant Mode. Reads its content from
/// `ChatStore.shared` by id, so updates from Pipeline propagate automatically
/// via @Observable. While the window is open, the next assistant hotkey
/// continues the displayed thread; closing the window (X, Done button, or
/// programmatic close) ends it — the next call starts fresh. After a REPLACE
/// turn the window never opens; in that case, continuation falls back to
/// selection-overlap with the previous reply
/// (Pipeline.shouldContinueConversation).
///
/// Deliberately *not* the chat window, even though they now show the same
/// threads out of the same store. This one is summoned by a hotkey over
/// whatever app the user is writing in, so it stays a floating panel you read
/// and dismiss. "Continue in chat" is the door to the other one, for when the
/// answer needs tools rather than another sentence.
@MainActor
final class AssistantResultController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var displayedThreadID: UUID?

    /// Called when the user closes the window (X or Done). AppState wires
    /// this to `pipeline.endActiveConversation()` so the next assistant
    /// call starts fresh.
    var onWindowClosed: (() -> Void)?

    /// Called when a thread is displayed so the pipeline can switch its active
    /// thread to match what's on screen.
    var onThreadDisplayed: ((UUID) -> Void)?

    /// True while the window is on-screen. Pipeline asks this when deciding
    /// whether the next assistant call is a continuation.
    var isWindowVisible: Bool {
        window?.isVisible ?? false
    }

    /// Thread id currently displayed *and* visible. Used by Pipeline's
    /// continuation check. Returns nil when the window is hidden so a closed
    /// window doesn't lock the next call into the wrong thread.
    var currentThreadID: UUID? {
        guard isWindowVisible else { return nil }
        return displayedThreadID
    }

    /// Update the window to show a given thread. `surface` true brings it to
    /// the front (DRAFT mode, paste-fallback, or a reopen). `surface` false
    /// only re-renders if the window is already visible — used for REPLACE
    /// turns that happen while the user is following along.
    func showThread(id: UUID, surface: Bool) {
        displayedThreadID = id
        let alreadyVisible = window?.isVisible ?? false
        guard surface || alreadyVisible else { return }

        let window = ensureWindow()
        let root = AssistantResultView(
            threadID: id,
            onCopy: { [weak self] text in self?.copyToClipboard(text) },
            onContinueInChat: { [weak self] in self?.continueInChat(id) },
            onClose: { [weak self] in self?.requestClose() }
        )
        window.contentViewController = NSHostingController(rootView: root)
        window.title = "Dictator Assistant"
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        onThreadDisplayed?(id)
    }

    /// Hands the thread to the chat window, where it can use tools and files.
    ///
    /// Closes this window on the way: the same thread open in two places, both
    /// able to append to it, is a race nobody asked for — and the user has just
    /// said which of the two they want.
    private func continueInChat(_ id: UUID) {
        ChatStore.shared.promote(id: id)
        requestClose()
        ChatWindowController.shared.show()
        ChatWindowController.shared.select(threadID: id)
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
            displayedThreadID = nil
            onWindowClosed?()
        }
    }
}

private struct AssistantResultView: View {
    let threadID: UUID
    let onCopy: (String) -> Void
    let onContinueInChat: () -> Void
    let onClose: () -> Void

    @State private var store = ChatStore.shared
    @State private var copyFeedback = false

    /// Demo mode resolves fixture threads by id first, so the window opens on
    /// fictional content while a recording is running.
    private var thread: ChatThread? {
        DemoMode.shared.thread(id: threadID, real: store.thread(id: threadID))
    }

    /// The transcript as turn pairs. The window has always shown a turn — the
    /// instruction and its reply together — rather than a run of messages, and
    /// that reads better for a hotkey flow than a chat log would.
    private var turns: [ConversationTurn] { thread?.assistantTurns ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let thread {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let comp = thread.compaction {
                                CompactionNote(summary: comp.summary)
                            }
                            ForEach(turns) { turn in
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
                    .onChange(of: turns.last?.id) { _, newID in
                        if let newID {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let lastID = turns.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                if let engine = AppState.shared.settings.activeLLMEngine(),
                   thread.isApproachingContextLimit(engine: engine) {
                    ApproachingLimitChip()
                }
                footer
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
        if thread != nil {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.indigo)
                    .font(.system(size: 13, weight: .semibold))
                Text(turns.count == 1 ? "1 turn" : "\(turns.count) turns")
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

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            // A clear, persistent "it's on your clipboard" marker — the HUD's
            // version fades after a few seconds, so the only lasting copy
            // confirmation lives here, where the user is reading the reply.
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11, weight: .semibold))
                Text("Copied to clipboard")
                    .font(.system(size: 11, weight: .semibold))
                Text("· \u{2318}V to paste anywhere")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.green.opacity(0.12)))
            .help("Stays on your clipboard until you copy something else. Closing this window ends the conversation.")
            Spacer()
            // The door to the other half of the app: same thread, same store,
            // but tools, files and a keyboard. This is the whole reason the two
            // conversation types were merged — an assistant reply that nearly
            // worked used to be a dead end.
            Button("Continue in Chat…", action: onContinueInChat)
                .help("Open this conversation in the chat window, where the assistant can use tools and write files.")
            if let last = turns.last {
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

    // The window shows every turn — including ones compacted away from the LLM
    // payload. The user asked for what's on screen to stay honest: "we want it
    // to be clear what has gone on throughout the conversation". The
    // CompactionNote at the top is what signals that the older ones no longer
    // count toward the model's context.
}

private struct TurnRow: View {
    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Captured context is the user's own screen — never shown while
            // demo mode is on.
            if let context = turn.context, !DemoMode.shared.isOn {
                ContextNote(context: context)
            }
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

/// Per-turn banner showing what context Assistant Mode pulled in — the text it
/// read around the cursor and what the vision model saw — so the user can tell
/// at a glance whether a turn had the context it needed, and expand to see the
/// actual captured text. Directly answers "did it manage to read my screen?".
private struct ContextNote: View {
    let context: CapturedContextInfo
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: context.hasVision ? "eye.fill" : "eye")
                    .foregroundStyle(context.hasVision ? .teal : .secondary)
                    .font(.system(size: 10, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if context.hasDocumentText || context.hasVision {
                    Button(expanded ? "Hide context" : "Show context") { expanded.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if context.hasDocumentText {
                        labeled("Text around your cursor", context.documentText)
                    }
                    if context.hasVision {
                        labeled("What the vision model saw", context.visionDescription)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.teal.opacity(0.08))
        )
    }

    private var summary: String {
        var parts: [String] = []
        if context.hasDocumentText {
            parts.append("read cursor text")
        } else {
            parts.append(context.documentNote.isEmpty ? "no cursor text" : "no cursor text (\(context.documentNote))")
        }
        if context.termCount > 0 {
            parts.append("\(context.termCount) term\(context.termCount == 1 ? "" : "s")")
        }
        if context.visionAttempted {
            if context.hasVision {
                parts.append("saw the window")
            } else {
                parts.append(context.visionNote.isEmpty ? "vision read nothing" : "vision: \(context.visionNote)")
            }
        }
        return "Context: " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
