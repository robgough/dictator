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
        VStack(alignment: .leading, spacing: 6) {
            if let error = shell.engine.errorMessage ?? dictation.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if dictation.isActive {
                RecordingPanel(dictation: dictation)
            } else {
                inputRow
                modelFootnote
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.18), value: dictation.isActive)
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

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: dictation.begin) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dictate a message")
            .disabled(dictation.phase == .transcribing)

            TextField("Message", text: $shell.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .font(.system(size: 13))
                .focused(isFocused)
                .onSubmit(send)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            if shell.engine.isBusy {
                Button(action: shell.engine.cancel) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .disabled(shell.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
        }
    }

    /// Which model is answering, always visible.
    ///
    /// Small but never hidden: the quality gap between a 2B and a 12B is the
    /// single biggest thing shaping what comes back, and someone who has
    /// forgotten which one they're on has no way to calibrate what they read.
    @ViewBuilder
    private var modelFootnote: some View {
        let id = state.settings.llmModelID
        let name = ModelCatalog.llm(id: id)?.displayName ?? id
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text("\(name) · running on this Mac")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.leading, 38)
    }

    private func send() {
        guard !shell.engine.isBusy else { return }
        onSend()
    }
}

/// Takes over the composer while recording.
///
/// The text field goes away entirely: there is nothing to type into mid-
/// sentence, and leaving it there implies otherwise. What replaces it is a
/// live meter — proof it is hearing you — and the only two decisions that
/// matter, throw it away or send it.
private struct RecordingPanel: View {
    let dictation: ChatDictation
    @State private var elapsed: TimeInterval = 0

    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Button(action: dictation.cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: .circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Discard")

            HStack(spacing: 10) {
                if dictation.phase == .transcribing {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .opacity(dictation.phase == .recording ? 1 : 0.35)
                    Waveform(level: dictation.level, tint: .red, barCount: 24, height: 22)
                    Text(timestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            Button {
                dictation.finish(send: true)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.tint, in: .circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(dictation.phase == .transcribing)
            .help("Stop and send")
        }
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
