import SwiftUI

/// A mic or Assist control that sits inside a bar: the Scratchpad's
/// accessory row (the Dictate screen uses `MorphRecordButton`). Idle, a
/// tinted icon (with a title when there's room); while it's the active
/// recorder it widens to fill the bar with listening bars and a hint, and
/// while its words are being worked on, a tap cancels.
///
/// Same press rules as everywhere else: hold to talk and let go to stop,
/// or tap to start and tap again to stop.
struct RecordKey: View {
    let tint: Color
    let icon: String
    var title: String? = nil
    let label: String
    let mode: RecordingViewModel.RecordingMode
    @Bindable var viewModel: RecordingViewModel
    let height: CGFloat
    /// What it says while the words are being worked on.
    var busyLabel = "Transcribing…"
    /// The recording was started for the user (the keyboard opened the
    /// app and began it), so the first touch stops it rather than being
    /// the start of a hold.
    var autoStarted = false
    /// Whether a press can start a recording. Not `.disabled()`, which
    /// would also swallow the tap that cancels this key's own processing.
    var enabled = true
    let onPress: () -> Void
    let onRelease: () -> Void
    var onBlocked: () -> Void = {}

    @Environment(\.isEnabled) private var environmentEnabled
    private var isEnabled: Bool { enabled && environmentEnabled }
    @State private var isPressed = false
    @State private var isLatched = false
    @State private var pressStartedAt: Date?

    private static let holdThreshold: TimeInterval = 0.35

    private var isMine: Bool { viewModel.recordingMode == mode }
    private var isCapturing: Bool { isMine && viewModel.status.isCapturing }
    private var isTranscribing: Bool {
        if isMine, case .transcribing = viewModel.status { return true }
        return false
    }
    private var active: Bool { isCapturing || isTranscribing }
    private var level: Float {
        if isMine, case let .recording(l) = viewModel.status { return l }
        return 0
    }
    private var blocked: Bool { MicBlocker.current(viewModel) != nil }
    /// Another recording owns the mic.
    private var busyElsewhere: Bool {
        guard !isMine else { return false }
        if viewModel.status.isCapturing { return true }
        if case .transcribing = viewModel.status { return true }
        return false
    }
    private var roomy: Bool { height >= 44 }

    var body: some View {
        HStack(spacing: 10) {
            if isTranscribing {
                ProgressView().controlSize(.small).tint(tint)
                Text(viewModel.isModelLoading ? "Waiting…" : busyLabel)
                    .font(roomy ? .callout.weight(.medium) : .footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if roomy {
                    Text("Tap to cancel")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            } else if isCapturing {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                Waveform(level: level, tint: tint, height: height * 0.45)
                    .id(viewModel.recordingStartCount)
                Spacer(minLength: 0)
                Text(isLatched || autoStarted ? "Tap to stop" : "Release to stop")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                RecordGlyph(name: icon, size: roomy ? 22 : 20)
                    .foregroundStyle(tint.opacity(dimmed ? 0.3 : 1))
                    .contentTransition(.symbolEffect(.replace))
                if let title {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(dimmed ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, active ? (roomy ? 20 : 12) : 0)
        .frame(width: active || title != nil ? nil : height + 6, height: height)
        .frame(maxWidth: active || title != nil ? .infinity : nil)
        .contentShape(.rect)
        .scaleEffect(isPressed ? 0.95 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
        } onPressingChanged: { pressing in
            pressingChanged(pressing)
        }
        .onChange(of: isMine) { _, mine in if !mine { isLatched = false } }
        .onChange(of: viewModel.status.isCapturing) { _, capturing in
            if !capturing { isLatched = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isTranscribing ? "Cancel" : isCapturing ? "Stop" : label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if isTranscribing { viewModel.cancelProcessing(); return }
            guard isEnabled, !blocked, !busyElsewhere else { return }
            if isCapturing { onRelease() } else { isLatched = true; onPress() }
        }
    }

    private var dimmed: Bool { !isEnabled || blocked || busyElsewhere }

    private func pressingChanged(_ pressing: Bool) {
        // Cancelling works even when the key is otherwise disabled —
        // Assist greys out on an empty transcript, but its own
        // "Applying…" must still be stoppable.
        if isTranscribing {
            if pressing { viewModel.cancelProcessing() }
            return
        }
        guard isEnabled else { return }
        if blocked {
            if pressing { onBlocked() }
            return
        }
        if busyElsewhere { return }
        if pressing, !isPressed {
            isPressed = true
            if isCapturing && autoStarted {
                // Started for the user: this touch is the stop.
                isLatched = true
            } else if !isLatched {
                pressStartedAt = Date()
                onPress()
            }
        } else if !pressing, isPressed {
            isPressed = false
            if isLatched {
                isLatched = false
                onRelease()
            } else {
                let elapsed = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                pressStartedAt = nil
                if elapsed >= Self.holdThreshold {
                    onRelease()
                } else {
                    isLatched = true
                }
            }
        }
    }
}
