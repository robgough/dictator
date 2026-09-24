import SwiftUI

/// The finished meeting's side panel: its details, or a conversation about it.
struct MeetingSidePanel: View {
    @Bindable var session: MeetingSession
    @Bindable var assistant: MeetingAssistantController
    @Binding var tab: String

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $tab) {
                Text("Details").tag("details")
                Text("Ask").tag("ask")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if tab == "ask" {
                MeetingChatPanel(session: session, assistant: assistant)
            } else {
                MeetingInspector(session: session)
            }
        }
    }
}

/// A conversation about one meeting. Questions go in at the bottom; answers
/// come back with the times they're drawn from, and a request to change the
/// notes comes back as a proposal to apply rather than an edit already made.
struct MeetingChatPanel: View {
    @Bindable var session: MeetingSession
    @Bindable var assistant: MeetingAssistantController
    @FocusState private var composerFocused: Bool

    private static let suggestions = [
        "What was decided?",
        "What did I agree to do?",
        "What's still unresolved?",
        "Draft a follow-up email to everyone",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if assistant.messages.isEmpty {
                            emptyState
                        }
                        ForEach(assistant.messages) { message in
                            MessageRow(message: message, speakers: session.meta.speakers,
                                       onSeek: { session.pendingSeek = $0 }) {
                                assistant.apply(message)
                            }
                            .id(message.id)
                        }
                        if assistant.isRunning {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading the meeting…").font(.callout).foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: assistant.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: assistant.isRunning) { _, running in
                    if running { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }
            if let error = assistant.errorText {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            composer
        }
        // Only when asked (the Assistant button, ⌘⌥A) — never just because
        // the panel appeared, which would take focus from wherever it was.
        .onChange(of: assistant.focusRequests) { _, _ in composerFocused = true }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this meeting")
                .font(.headline)
            Text("Answers come from the notes, your pad and the transcript, with the time each came from. Ask it to change the notes and you'll see the change before it's made.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button { assistant.send(suggestion) } label: {
                        Text(suggestion)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .disabled(!assistant.canRun)
                }
            }
            .padding(.top, 4)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(assistant.isListening ? "Listening…" : "Ask about this meeting…",
                          text: $assistant.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { assistant.send() }
                Button { assistant.toggleListening() } label: {
                    Image(systemName: assistant.isListening ? "stop.circle.fill" : "mic")
                        .foregroundStyle(assistant.isListening ? Color.red : .secondary)
                }
                .buttonStyle(.borderless)
                .help(assistant.isListening ? "Stop dictating" : "Dictate a question (⌘⌥A dictates and sends)")
                .disabled(assistant.isTranscribing)
                Button { assistant.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(assistant.draft.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isRunning || !assistant.canRun)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                if let name = assistant.providerName {
                    Text("Answers from \(name)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(ProviderRegistry.shared.requirementMessage ?? "No model is set up to answer.")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                if !assistant.messages.isEmpty {
                    Button("Clear") { assistant.clear() }
                        .buttonStyle(.link)
                        .font(.caption2)
                        .help("Start the conversation about this meeting again")
                }
            }
        }
        .padding(12)
    }
}

private struct MessageRow: View {
    let message: MeetingChatMessage
    let speakers: [MeetingMeta.Speaker]
    /// Times in an answer jump the transcript to that moment.
    let onSeek: (Double) -> Void
    let onApply: () -> Void
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.15)))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                MarkdownNotesView(markdown: message.text, speakers: speakers, onSeek: onSeek)
                    .font(.callout)
                if let notes = message.proposedNotes {
                    proposal(notes)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func proposal(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Revised notes", systemImage: "doc.badge.ellipsis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.purple)
            Text(notes)
                .font(.caption.monospaced())
                .lineLimit(8)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if message.applied {
                Label("Applied to the notes", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Button("Apply to the notes", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.purple.opacity(0.07)))
    }
}
