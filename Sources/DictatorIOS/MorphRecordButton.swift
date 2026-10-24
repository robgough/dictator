import SwiftUI
import UIKit

extension Color {
    /// Speaking: the mic and a dictation in progress.
    static let dictatorSpeak = Color(red: 0xE5 / 255, green: 0x38 / 255, blue: 0x3B / 255)
    /// Assist: a spoken instruction in progress.
    static let dictatorAssist = Color(red: 0x6A / 255, green: 0x4B / 255, blue: 0xE0 / 255)
}

/// The Dictate screen's one control, which changes with what you're doing.
///
/// - Idle, empty transcript: one large mic.
/// - Idle with text: Copy · Assist · Mic, under the thumb.
/// - Recording: the mic stretches into a pill (live meter, timer, ↑ send)
///   and ✕ cancel pours out beside it. Violet for an Assist recording.
/// - Working: the pill shows a spinner; ✕ cancels the processing.
///
/// The mic and the pill are the same view throughout, so a hold that starts
/// a recording survives the morph: hold to talk and let go to send, or tap
/// to start and tap the pill to send. Pieces come and go as Liquid Glass
/// in one container, so they stretch out of the main button and tuck back
/// into it (borrowed from Hummingbird's composer).
struct MorphRecordButton: View {
    @Bindable var viewModel: RecordingViewModel
    /// The mic's resting symbol (plain, append or replace badge).
    let micIcon: String
    let onCopy: () -> Void

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false
    /// This press started the recording: on release it's either a hold
    /// (send) or a tap (keep recording).
    @State private var pressStartedRecording = false
    @State private var pressStartedAt: Date?
    /// This press landed on a recording already running: release sends.
    @State private var pressWillSend = false
    /// Which recording the current press belongs to, so a release can't send
    /// a different one (e.g. after ✕ under a held finger).
    @State private var pressRecording = 0
    @State private var recordingStartedAt = Date()
    @State private var copied = false
    @State private var copyReset: Task<Void, Never>?

    private static let holdThreshold: TimeInterval = 0.35
    static let primarySize: CGFloat = 64
    private static let secondarySize: CGFloat = 50

    enum Phase: Equatable { case idle, recording, working }

    private var isMine: Bool {
        viewModel.recordingMode == .dictation || viewModel.recordingMode == .assist
    }
    private var isTranscribingStatus: Bool {
        if case .transcribing = viewModel.status { return true }
        return false
    }
    private var phase: Phase {
        guard isMine else { return .idle }
        if viewModel.status.isCapturing { return .recording }
        if isTranscribingStatus { return .working }
        return .idle
    }
    /// Another tab or the keyboard owns the mic.
    private var busyElsewhere: Bool {
        !isMine && (viewModel.status.isCapturing || isTranscribingStatus)
    }
    private var isAssist: Bool { phase != .idle && viewModel.recordingMode == .assist }
    private var tint: Color { isAssist ? .dictatorAssist : .dictatorSpeak }
    private var hasText: Bool { !viewModel.transcript.isEmpty }
    private var showsCluster: Bool { phase == .idle && hasText }
    private var assistShown: Bool { showsCluster && AppleFoundationAssist.isAvailable }
    private var assistEnabled: Bool {
        !viewModel.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busyElsewhere
    }
    private var level: Float {
        if phase == .recording, case let .recording(l) = viewModel.status { return l }
        return 0
    }

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 12) {
                if phase != .idle {
                    cancelButton
                        .transition(pieceTransition)
                }
                if showsCluster {
                    copyButton
                        .transition(pieceTransition)
                }
                if assistShown {
                    assistButton
                        .transition(pieceTransition)
                }
                primary
            }
        }
        .frame(maxWidth: .infinity)
        .animation(motion, value: phase)
        .animation(motion, value: showsCluster)
        .animation(motion, value: isAssist)
        .onChange(of: viewModel.recordingStartCount, initial: true) { _, _ in
            recordingStartedAt = Date()
        }
        .onChange(of: phase) { _, new in
            if new != .recording { pressWillSend = false }
        }
    }

    // MARK: Pieces

    private var cancelButton: some View {
        Button(action: cancel) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: Self.secondarySize, height: Self.secondarySize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("cancel", in: glass)
        .accessibilityLabel(phase == .working ? "Cancel processing" : "Cancel recording")
    }

    private var copyButton: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.secondarySize, height: Self.secondarySize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("copy", in: glass)
        .accessibilityLabel("Copy")
    }

    private var assistButton: some View {
        Button {
            viewModel.startAssistRecording()
        } label: {
            AssistGlyph()
                .fill(Color.dictatorAssist.opacity(assistEnabled ? 1 : 0.3))
                .frame(width: 23, height: 23)
                .frame(width: Self.secondarySize, height: Self.secondarySize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!assistEnabled)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("assist", in: glass)
        .accessibilityLabel("Assist")
    }

    /// The mic, stretched into the pill while recording or working. One view
    /// with one gesture for the whole lifecycle — see the type comment.
    private var primary: some View {
        HStack(spacing: 12) {
            switch phase {
            case .idle:
                Image(systemName: micIcon)
                    .font(.system(size: 26, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .opacity(busyElsewhere ? 0.45 : 1)
                    .transition(.opacity)
            case .recording:
                Waveform(level: level, tint: .white, barCount: 14, height: 24)
                    .frame(width: 84)
                    .id(viewModel.recordingStartCount)
                    .transition(listeningTransition)
                TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(recordingStartedAt)))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
                .transition(listeningTransition)
                Image(systemName: "arrow.up")
                    .font(.system(size: 20, weight: .bold))
                    .transition(.opacity)
            case .working:
                ProgressView()
                    .tint(.white)
                    .transition(.opacity)
                Text(workingLabel)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, phase == .idle ? 0 : 22)
        .frame(minWidth: Self.primarySize)
        .frame(height: Self.primarySize)
        .contentShape(.capsule)
        .glassEffect(.regular.tint(primaryTint).interactive(), in: .capsule)
        .glassEffectID("primary", in: glass)
        .scaleEffect(isPressed ? 0.95 : 1)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
        } onPressingChanged: { pressing in
            pressingChanged(pressing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(primaryLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { primaryAccessibilityAction() }
    }

    private var primaryTint: Color {
        switch phase {
        case .idle: busyElsewhere ? Color(.systemGray3) : .dictatorSpeak
        case .recording: tint
        case .working: tint.opacity(0.6)
        }
    }

    private var primaryLabel: String {
        switch phase {
        case .idle: hasText ? "Dictate more" : "Dictate"
        case .recording: "Send"
        case .working: workingLabel
        }
    }

    private var workingLabel: String {
        if viewModel.isModelLoading { return "Waiting" }
        return isAssist ? "Applying" : "Transcribing"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    // MARK: Motion

    /// A soft spring with a little give, so the glass stretches and settles.
    /// With Reduce Motion the pieces simply cross-fade.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .bouncy(duration: 0.45, extraBounce: 0.06)
    }

    private var pieceTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.3, anchor: .trailing).combined(with: .opacity)
    }

    /// The meter and timer grow out from the arrow as the pill stretches.
    private var listeningTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .trailing).combined(with: .opacity)
    }

    // MARK: Actions

    private func pressingChanged(_ pressing: Bool) {
        if pressing, !isPressed {
            switch phase {
            case .working:
                return
            case .idle:
                guard !busyElsewhere else { return }
                isPressed = true
                pressStartedAt = Date()
                viewModel.startRecording()
                pressStartedRecording = viewModel.status.isCapturing
                pressRecording = viewModel.recordingStartCount
            case .recording:
                // A tap-started (or keyboard-started) recording: this
                // touch is the send.
                isPressed = true
                pressWillSend = true
                pressRecording = viewModel.recordingStartCount
            }
        } else if !pressing, isPressed {
            isPressed = false
            if pressStartedRecording {
                pressStartedRecording = false
                let elapsed = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                pressStartedAt = nil
                // Held: letting go sends. Tapped: keep recording.
                if elapsed >= Self.holdThreshold { send() }
            } else if pressWillSend {
                pressWillSend = false
                send()
            }
        }
    }

    private func primaryAccessibilityAction() {
        switch phase {
        case .idle:
            guard !busyElsewhere else { return }
            viewModel.startRecording()
        case .recording:
            pressRecording = viewModel.recordingStartCount
            send()
        case .working:
            break
        }
    }

    private func send() {
        guard phase == .recording, viewModel.recordingStartCount == pressRecording else { return }
        if viewModel.recordingMode == .assist {
            Task { await viewModel.stopAssistRecording() }
        } else {
            Task { await viewModel.stopRecording() }
        }
    }

    private func cancel() {
        switch phase {
        case .recording: viewModel.cancelRecording()
        case .working: viewModel.cancelProcessing()
        case .idle: break
        }
        pressStartedRecording = false
        pressWillSend = false
    }

    private func copy() {
        onCopy()
        copied = true
        AccessibilityNotification.Announcement("Copied").post()
        copyReset?.cancel()
        copyReset = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
