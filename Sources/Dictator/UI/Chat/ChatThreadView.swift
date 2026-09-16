import SwiftUI

/// The transcript plus the composer.
struct ChatThreadView: View {
    @Bindable var shell: ChatShellModel
    @Environment(AppState.self) private var state
    @State private var store = ChatStore.shared
    @FocusState private var composerFocused: Bool
    @State private var dropTargeted = false

    private var thread: ChatThread? {
        shell.selectedThreadID.flatMap { store.thread(id: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            ChatComposer(
                shell: shell,
                isFocused: $composerFocused,
                onSend: send
            )
        }
        .sheet(item: approvalBinding) { pending in
            ChatToolApprovalSheet(
                pending: pending,
                onApprove: { always in shell.engine.approve(always: always) },
                onDeny: { shell.engine.deny() }
            )
        }
        .onAppear { composerFocused = true }
        .onChange(of: shell.selectedThreadID) { composerFocused = true }
        // The whole pane, not just the composer: people drop a file on the
        // conversation, not on the text box.
        .dropDestination(for: URL.self) { urls, _ in
            shell.attach(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }


    private var approvalBinding: Binding<ChatEngine.PendingApproval?> {
        Binding(
            get: { shell.engine.pendingApproval },
            // Dismissing the sheet any other way (Escape) is a denial, not a
            // silent approval.
            set: { if $0 == nil { shell.engine.deny() } }
        )
    }

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ChatTrustWarning()
                        if let notice = shell.modelSwitchNotice {
                            ChatNoticeRow(text: notice, icon: "arrow.triangle.2.circlepath")
                        }
                        // In the stack rather than centred over it. As an overlay
                        // it floated independently of the warning, so the gap
                        // between the two changed with the window height and the
                        // pair drifted apart as you resized.
                        if isEmpty {
                            ChatEmptyState()
                                .padding(.top, 56)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(thread?.messages ?? []) { message in
                            // The reply currently streaming lives on the engine,
                            // not the store — writing it per token would reorder
                            // and re-render the whole thread list on every chunk.
                            ChatMessageRow(
                                message: message,
                                liveText: message.id == shell.engine.streamingMessageID
                                    ? shell.engine.visibleStreamingText : nil
                            )
                            .id(message.id)
                        }
                        if shell.engine.activity != .idle {
                            ChatActivityRow(activity: shell.engine.activity)
                        }
                        // A zero-height target to scroll to. Scrolling to the last
                        // *message* was the bug: with a LazyVStack the row is sized
                        // as it appears, so `scrollTo` aimed at a height that was
                        // still changing and landed part-way up a long reply. An
                        // empty anchor below everything has nothing to mis-measure.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchor)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // At least as tall as the pane, content pinned to its top.
                    //
                    // This is what makes the bottom anchor below behave. A scroll
                    // view told to anchor at the bottom hoists content *shorter
                    // than the viewport* down to the bottom of it — so a couple of
                    // messages sat just above the composer under a great slab of
                    // empty space that read as a giant blank header. Giving the
                    // stack a floor of one viewport means there is never anything
                    // to hoist: short threads start at the top, long ones still
                    // stick to the end.
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                // Pins to the newest content as the thread grows, including on
                // first open — without it a reopened chat starts at the top and you
                // scroll down through your own history to find the end. Safe to
                // apply unconditionally now that the stack above has a one-viewport
                // floor; on its own it mis-places every thread short enough to fit.
                .defaultScrollAnchor(.bottom)
                .onChange(of: thread?.messages.count) { scrollToEnd(proxy) }
                .onChange(of: shell.engine.streamingText) { throttledScrollToEnd(proxy) }
                .onChange(of: shell.engine.activity) { scrollToEnd(proxy) }
                .onChange(of: shell.selectedThreadID) {
                    // No animation when switching threads: animating a jump
                    // through someone else's conversation is just a smear.
                    scrollToEnd(proxy, animated: false)
                }
            }
        }
    }

    private var isEmpty: Bool { thread?.messages.isEmpty ?? true }

    private static let bottomAnchor = "chat.bottom"

    /// Scrolling on *every* token is what made a long reply feel like the
    /// window had hung: `scrollTo` forces a layout pass over the whole
    /// LazyVStack, and at thirty-odd tokens a second that is thirty full
    /// layouts a second on top of the text changing. Ten a second tracks the
    /// text just as well and leaves the main thread time to do anything else.
    @State private var lastScroll = Date.distantPast

    private func throttledScrollToEnd(_ proxy: ScrollViewProxy) {
        let now = Date()
        guard now.timeIntervalSince(lastScroll) > 0.1 else { return }
        lastScroll = now
        scrollToEnd(proxy, animated: false)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Streaming fires this on every chunk, and animating each one leaves
        // the scroll permanently chasing the text instead of tracking it.
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }

    private func send() {
        let text = shell.draft
        let attachments = shell.pendingAttachments
        shell.draft = ""
        shell.pendingAttachments = []
        shell.attachmentError = nil
        shell.engine.send(text, attachments: attachments)
    }
}

/// Prompt suggestions on an empty thread. They double as documentation: most
/// people won't guess that a local model can read their screen or their
/// journal unless something says so.
private struct ChatEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ask anything")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(
                    // One each for the three things that aren't guessable
                    // from a text box: it can see the screen, it knows what
                    // you've dictated, and you can put a file into it. The
                    // dropped-PDF line replaced "draft a reply to the email
                    // behind this window", which was a second way of saying
                    // the first one.
                    [
                        "What's on my screen right now?",
                        "Summarise what I dictated this week.",
                        "Summarise the PDF I've dropped in.",
                    ], id: \.self
                ) { example in
                    Text("“\(example)”")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ChatNoticeRow: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

private struct ChatActivityRow: View {
    let activity: ChatEngine.Activity

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch activity {
        case .idle: return ""
        case .loadingModel: return "Loading the model…"
        case .thinking: return "Thinking…"
        case .streaming: return "Writing…"
        case .awaitingApproval: return "Waiting for you…"
        case .runningTool(let name): return "\(name)…"
        // Worth saying plainly rather than showing a generic spinner: the
        // reply genuinely has stopped, and it's because dictation won.
        case .pausedForDictation: return "Paused — dictation is using the model"
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    /// Non-nil while this message is the one being streamed.
    var liveText: String?

    private var text: String { liveText ?? message.text }

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .leading, spacing: 5) {
                    if !text.isEmpty {
                        Text(text)
                            .textSelection(.enabled)
                    }
                    // Under the text: you wrote the sentence, then said what it
                    // was about. An attachment-only message shows just these.
                    if !message.attachments.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(message.attachments) { attachment in
                                ChatAttachmentChip(attachment: attachment)
                            }
                        }
                    }
                    // What the assistant hotkey was pointed at when this was
                    // spoken. Without it a migrated turn reads as "tighten
                    // this" with no sign of what "this" was — the instruction
                    // is half the message and the selection is the other half.
                    if let selection = message.selection, !selection.isEmpty {
                        ChatSelectionQuote(text: selection)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.tint.opacity(0.15), in: .rect(cornerRadius: 12))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                ChatMarkdownView(text: text, isStreaming: liveText != nil)
                // Where this reply went the first time round, for turns that
                // came in through the hotkey and were pasted somewhere before
                // the thread was ever opened here.
                if let delivery = message.delivery, !delivery.isEmpty {
                    Label(delivery, systemImage: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Only once the reply has finished arriving: acting on half a
                // sentence isn't useful, and a row of buttons flickering under
                // a streaming reply is a distraction while reading it.
                if liveText == nil, !text.isEmpty {
                    ChatReplyActions(text: text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ChatToolRow(message: message)
        case .failure:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

}

/// A tool call, collapsed to one line with the details on demand. Showing the
/// arguments matters — the spec asks clients to show what a tool is being
/// called with so people can spot a call they didn't want.
private struct ChatToolRow: View {
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(headline)
                        .font(.caption.weight(.medium))
                    if let server = message.serverName {
                        Text(server)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    // The file card carries its own show/hide, so a second
                    // chevron here would be two controls for one thing.
                    if message.producedFile == nil {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(message.producedFile != nil)

            // A produced file replaces the usual result blob: the card IS the
            // result, and showing the model's "Saved notes.md…" sentence above
            // it as well would just be the same fact twice.
            if let file = message.producedFile {
                ChatFileCard(file: file)
            } else if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let summary = message.toolCall?.argumentSummary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let result = message.toolResult {
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
        }
    }

    private var headline: String {
        if message.toolDenied { return "\(message.text) — declined" }
        if message.toolFailed { return "\(message.text) — failed" }
        if message.toolResult == nil { return "\(message.text)…" }
        return message.text
    }

    private var icon: String {
        if message.toolDenied { return "hand.raised" }
        if message.toolFailed { return "exclamationmark.triangle" }
        return "wrench.and.screwdriver"
    }

    private var tint: Color {
        if message.toolDenied { return .secondary }
        if message.toolFailed { return .orange }
        return .accentColor
    }
}

/// The standing caution at the top of every chat.
///
/// It stays for the life of the thread rather than being dismissible, because
/// what it warns about doesn't stop being true once you've read it — a small
/// local model is most dangerous on the fiftieth reply, when you've stopped
/// checking.
///
/// Which is exactly why it has to be quiet. It was a yellow card with a bold
/// heading and a five-sentence paragraph: it shouted the first time and was
/// scrolled past every time after. Now it's one muted line with the caution
/// colour left on the icon alone — still the first thing on the page, no longer
/// competing with the conversation.
private struct ChatTrustWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.yellow.mix(with: .secondary, by: 0.35))
                .padding(.top, 1)

            Text(warning)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 620, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }

    /// Four facts, in the order they matter: it's private, it's small, it lies
    /// fluently, check it. Cutting further starts dropping one of them.
    ///
    /// The Mac is mentioned once and does double duty — it's both the privacy
    /// claim and the reason the model is small. It used to be said here, again
    /// in the empty state and a third time in the footer, which reads as
    /// protesting too much.
    ///
    /// The model isn't named. The footer names it and is on screen the whole
    /// time, so repeating it here only made this line longer.
    private let warning =
        "This is a small model running on your own Mac — nothing you type leaves it, and "
        + "it's a tiny fraction of the size of ChatGPT or Claude. It will state untrue things "
        + "with complete confidence: invented dates, names, numbers and quotes, written as "
        + "fluently as the parts it gets right. Check anything that matters."
}

/// What you can do with a finished reply: copy it, or put it back where you
/// were working.
///
/// Insertion is the point. Assistant Mode can already type at your cursor
/// because the hotkey fires while the target app is still in front; a chat
/// window that has just spent four tool calls writing something has no such
/// luck, and the reply's usual fate is a manual copy, a ⌘-Tab, and a paste.
/// `ChatInsertion` remembers which app that was, so the button can say so.
private struct ChatReplyActions: View {
    let text: String

    @State private var insertion = ChatInsertion.shared
    @State private var copied = false
    @State private var inserting = false
    /// Which message the banner belongs to. `ChatInsertion` is a singleton, so
    /// without this every reply in the transcript shows the same outcome.
    @State private var owned = false

    var body: some View {
        HStack(spacing: 10) {
            action(copied ? "checkmark" : "doc.on.doc",
                   label: copied ? "Copied" : "Copy",
                   tint: copied ? .green : .secondary) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }

            if let target = insertion.targetName {
                action("text.insert", label: "Insert into \(target)", tint: .secondary) {
                    owned = true
                    inserting = true
                    Task {
                        await insertion.insert(text)
                        inserting = false
                    }
                }
                .disabled(inserting)
            }

            if owned, let outcome = insertion.lastOutcome {
                Label(outcome.message,
                      systemImage: outcome.isFailure
                        ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(outcome.isFailure ? .orange : .green)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: insertion.lastOutcome)
        .onChange(of: insertion.lastOutcome) { _, new in
            // Someone else's outcome cleared — stop claiming the banner.
            if new == nil { owned = false }
        }
    }

    private func action(
        _ symbol: String, label: String, tint: Color, run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            Label(label, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The text an Assistant Mode turn was about, quoted under the instruction.
///
/// Collapsed by default: a selection can be several paragraphs, and the
/// instruction is the part you scan for when reading back a conversation.
private struct ChatSelectionQuote: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.quote")
                    Text(expanded ? "Hide the text this was about"
                                  : "About \(text.count) characters of selected text")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
            }
        }
    }
}
