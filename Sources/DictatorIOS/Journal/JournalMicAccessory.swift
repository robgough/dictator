import SwiftUI

/// The Journal's mic, as the tab bar's accessory: a full-width "hold to
/// talk" bar above the tabs that slides in beside the tab icon when the bar
/// shrinks on scroll, so it's always under the thumb and never floats over
/// the page.
///
/// Same press rules as the Scratchpad's buttons (`ScratchpadRecordButton`):
/// hold to talk and let go to stop, or tap to start and tap again to stop.
/// While it's writing the entry down, a tap cancels it.
struct JournalMicAccessory: View {
    @Bindable var viewModel: RecordingViewModel

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var isPressed = false
    @State private var isLatched = false
    @State private var pressStartedAt: Date?
    @State private var blocker: MicBlocker?

    private static let holdThreshold: TimeInterval = 0.35

    private var isInline: Bool { placement == .inline }
    private var isMine: Bool { viewModel.recordingMode == .journal }
    private var isCapturing: Bool { isMine && viewModel.status.isCapturing }
    private var isTranscribing: Bool {
        if isMine, case .transcribing = viewModel.status { return true }
        return false
    }
    private var level: Float {
        if isMine, case let .recording(l) = viewModel.status { return l }
        return 0
    }
    private var blocked: Bool { MicBlocker.current(viewModel) != nil }
    /// Another tab's recording owns the mic.
    private var busyElsewhere: Bool {
        !isMine && (viewModel.status.isCapturing || { if case .transcribing = viewModel.status { return true }; return false }())
    }

    var body: some View {
        HStack(spacing: 0) {
            micArea
            if !isCapturing && !isTranscribing {
                Divider()
                    .frame(height: isInline ? 18 : 24)
                Button {
                    JournalModel.shared.select(key: JournalModel.shared.todayKey)
                    JournalModel.shared.requestPhoto()
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: isInline ? 15 : 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: isInline ? 40 : 56)
                        .frame(maxHeight: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(JournalCamera.isAvailable ? "Take a photo" : "Add a photo")
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isCapturing)
        .micBlockerAlert($blocker, viewModel: viewModel)
    }

    /// The hold-to-talk part: everything left of the camera.
    private var micArea: some View {
        HStack(spacing: 10) {
            if isTranscribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.journalAccent)
            } else {
                Image(systemName: isCapturing ? "stop.fill" : "mic.fill")
                    .font(.system(size: isInline ? 15 : 18, weight: .semibold))
                    .foregroundStyle(.red.opacity(blocked || busyElsewhere ? 0.35 : 1))
                    .contentTransition(.symbolEffect(.replace))
            }
            if isCapturing {
                Waveform(level: level, tint: .red, height: isInline ? 16 : 20)
                    .id(viewModel.recordingStartCount)
                if !isInline {
                    Spacer(minLength: 0)
                    Text(isLatched ? "Tap to stop" : "Release to stop")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if !isInline {
                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(blocked || busyElsewhere ? .secondary : .primary)
                Spacer(minLength: 0)
                if isTranscribing {
                    Text("Tap to cancel")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if isTranscribing {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, isInline ? 12 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isInline ? .center : .leading)
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isCapturing)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
        } onPressingChanged: { pressing in
            pressingChanged(pressing)
        }
        .onChange(of: isMine) { _, mine in if !mine { isLatched = false } }
        .onChange(of: viewModel.status.isCapturing) { _, capturing in
            if !capturing { isLatched = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isTranscribing ? "Cancel entry" : isCapturing ? "Stop and save entry" : "Dictate a journal entry")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if isTranscribing { viewModel.cancelProcessing() }
            else if isCapturing { stop() } else { start() }
        }
    }

    private var label: String {
        if isTranscribing { return "Writing it down…" }
        if busyElsewhere { return "Recording on another tab" }
        return "Hold to add to today"
    }

    private func pressingChanged(_ pressing: Bool) {
        if blocked {
            if pressing { handleBlockedMic(viewModel, showing: $blocker) }
            return
        }
        if isTranscribing {
            if pressing { viewModel.cancelProcessing() }
            return
        }
        if busyElsewhere { return }
        if pressing, !isPressed {
            isPressed = true
            if !isLatched {
                pressStartedAt = Date()
                start()
            }
        } else if !pressing, isPressed {
            isPressed = false
            if isLatched {
                isLatched = false
                stop()
            } else {
                let elapsed = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                pressStartedAt = nil
                if elapsed >= Self.holdThreshold {
                    stop()
                } else {
                    isLatched = true
                }
            }
        }
    }

    private func start() {
        // An entry always goes to today; show the page it's landing on.
        JournalModel.shared.select(key: JournalModel.shared.todayKey)
        viewModel.startJournalRecording()
    }

    private func stop() {
        Task { await viewModel.stopJournalRecording() }
    }
}
