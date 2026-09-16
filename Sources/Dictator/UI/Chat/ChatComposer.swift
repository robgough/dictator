import AppKit
import SwiftUI

/// The message box, and the recording panel that replaces it while dictating.
///
/// The mic records straight into the box (`ChatDictation`) rather than driving
/// the dictation pipeline. Going through the pipeline meant a chat prompt paid
/// for formatting passes, a window-vision capture of whatever sat behind the
/// window, an Accessibility read and a synthetic paste — none of which a prompt
/// needs, all of which made it slow. The global dictation hotkey still works
/// here like anywhere else, for anyone who prefers it.
struct ChatComposer: View {
    @Bindable var shell: ChatShellModel
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    @Environment(AppState.self) private var state

    private var dictation: ChatDictation { shell.dictation }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = shell.engine.errorMessage ?? dictation.errorMessage
                ?? shell.attachmentError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            // Above the box, not inside it: an attachment is a thing you've
            // added to the message, and it stays visible while you type the
            // sentence that goes with it.
            if !shell.pendingAttachments.isEmpty || shell.attachmentsInFlight > 0 {
                ChatPendingAttachments(
                    attachments: shell.pendingAttachments,
                    busyCount: shell.attachmentsInFlight,
                    onRemove: shell.removeAttachment)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            inputRow
                .padding(12)

            footer
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: dictation.isActive)
        .animation(.easeOut(duration: 0.18), value: shell.pendingAttachments)
        .onAppear {
            dictation.onTranscript = { text, send in
                // Append: dictating twice, or dictating after typing, should
                // add to what's there rather than replace it.
                let existing = shell.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                shell.draft = existing.isEmpty ? text : existing + " " + text
                isFocused.wrappedValue = true
                // Through the guarded path, not `onSend` directly: that one
                // clears the draft before handing it to the engine, and the
                // engine drops the turn if it's already busy — so a voice
                // message sent mid-reply would vanish without a trace.
                if send { self.send() }
            }
        }
        .onChange(of: shell.selectedThreadID) { dictation.cancel() }
    }

    /// Text field and its two buttons — or, while dictating, the recorder
    /// growing out of where the microphone was.
    ///
    /// The recorder replaces the *field*, not the whole bar. Taking over the
    /// full width made it look like a modal state change for something that is
    /// just another way of typing; expanding a pill out of the mic button and
    /// fading the field reads as the same row doing a different job. The footer
    /// stays put throughout, so the model never disappears mid-sentence.
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if dictation.isActive {
                Spacer(minLength: 0)
                RecordingPill(dictation: dictation)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.25, anchor: .trailing)
                            .combined(with: .opacity),
                        removal: .opacity))

                iconButton("xmark", size: 13, help: "Discard", action: dictation.cancel)
                    .keyboardShortcut(.cancelAction)

                roundButton("arrow.up.circle.fill", help: "Stop and send") {
                    dictation.finish(send: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(dictation.phase == .transcribing)
            } else {
                iconButton("paperclip", size: 15, help: "Attach files…", action: chooseFiles)
                    .disabled(shell.engine.isBusy)

                TextField("Message", text: $shell.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .font(.system(size: 13))
                    .focused(isFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
                    .transition(.opacity)

                if shell.engine.isBusy {
                    roundButton("stop.circle.fill", help: "Stop", action: shell.engine.cancel)
                } else {
                    roundButton("arrow.up.circle.fill", help: "Send", action: send)
                        .disabled(!canSend)
                }

                iconButton("mic.fill", size: 17, help: "Dictate a message",
                           action: dictation.begin)
                    .disabled(dictation.phase == .transcribing)
            }
        }
    }

    /// The filled send/stop glyph.
    ///
    /// Shares `iconButton`'s 30×30 box on purpose. These were bare images, so
    /// in a bottom-aligned row their glyph sat flush with the baseline while
    /// the paperclip and microphone were centred in a taller box — the send
    /// button ended up a few points below its neighbours. Same box, same
    /// centre, whatever the glyph's own size.
    private func roundButton(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(
        _ symbol: String, size: CGFloat, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The strip under the message box: which model is answering, and a way
    /// into this chat's folder.
    ///
    /// Always visible, including while dictating — the model is the single
    /// biggest thing shaping what comes back, and hiding it the moment someone
    /// starts talking is exactly when they'd want to check.
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(modelName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("· on this Mac")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            Button(action: openFilesFolder) {
                Label("Chat files", systemImage: "folder")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Show this chat's files in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.3))
    }

    private var modelName: String {
        // Not `llmModelID` unconditionally: on the Apple engine that holds
        // whichever MLX model the user would switch *to*, so the footer named a
        // model that wasn't going to answer.
        guard state.settings.llmEngine != .apple else { return "Apple's on-device model" }
        let id = state.settings.llmModelID
        return ModelCatalog.llm(id: id)?.displayName ?? id
    }

    /// Opens the chat's folder, making it first if nothing has been saved yet —
    /// otherwise the button does nothing on a new chat, which reads as broken.
    private func openFilesFolder() {
        guard let id = shell.selectedThreadID,
              let thread = ChatStore.shared.thread(id: id),
              let folder = try? ChatFiles.folder(for: thread)
        else { return }
        if thread.filesFolderName != folder.folderName {
            var updated = thread
            updated.filesFolderName = folder.folderName
            ChatStore.shared.upsert(updated)
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    /// An attachment with no typed message still sends: dragging a PDF in and
    /// saying nothing plainly means "read this".
    private var canSend: Bool {
        !shell.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !shell.pendingAttachments.isEmpty
    }

    private func send() {
        guard !shell.engine.isBusy, canSend else { return }
        onSend()
    }

    // MARK: - Attaching

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "These are copied into this chat's folder."
        panel.prompt = "Attach"
        panel.begin { response in
            guard response == .OK else { return }
            shell.attach(panel.urls)
        }
    }

}

/// The recorder: a pill that grows out of the microphone button.
///
/// Sized to its content rather than to the window. The first version stretched
/// across the whole row, which at 900pt gave 35pt-wide bars and read as a bar
/// chart of nothing in particular — and taking over the full bar made a second
/// way of typing look like a modal state change.
private struct RecordingPill: View {
    let dictation: ChatDictation
    @State private var elapsed: TimeInterval = 0

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    /// The assistant's own colour, not a generic recording red.
    ///
    /// `CaptureKind.assistant.tint` is what every other live meter in the app
    /// wears when the assistant is listening — the HUD, the island, the
    /// Settings sidebar badge — so matching it keeps one colour per flow across
    /// the whole app.
    private static let tint = CaptureKind.assistant.tint

    var body: some View {
        HStack(spacing: 9) {
            if dictation.phase == .transcribing {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(Self.tint)
                    .frame(width: 7, height: 7)
                    .opacity(dictation.phase == .recording ? 1 : 0.35)
                Waveform(level: dictation.level, tint: Self.tint, barCount: 40, height: 18)
                    .frame(width: 180)
                Text(timestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))
        .onReceive(tick) { _ in
            guard let started = dictation.startedAt else { return }
            elapsed = Date().timeIntervalSince(started)
        }
    }

    private var timestamp: String {
        let total = Int(elapsed)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
