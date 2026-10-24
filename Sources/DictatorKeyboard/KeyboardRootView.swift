import SwiftUI

/// The keyboard's SwiftUI layout: two short rows on every device.
///
/// - Top row: Undo · Paste · Assist · Mic.
/// - Bottom row: (globe) · space · return · ⌫.
///
/// While a recording is in flight the top row becomes the app's ✕ and pill
/// (red for dictation, violet for Assist), the mic stretching across the
/// room Undo, Paste and Assist give up, with the live meter inside it. Tap
/// the pill (↑) to send; the text lands at the cursor. The bottom row stays
/// live throughout. Same morph as the Dictate screen's `MorphRecordButton`,
/// at the keyboard's height.
///
/// With a warm mic in the background (`session` is non-nil) Dictate and
/// Assist record in place; the mic carries a small dot while it's warm.
/// Without one they open Dictator, as they always have, and the result
/// comes back here when the user returns.
///
/// On wide screens (iPad, the open iPhone Duo) the rows stay a centred band
/// rather than stretching. A partly folded Duo splits them around the
/// crease: Undo and Paste on the left half, the rest on the right. Pinched
/// into the iPad's floating keyboard, Paste shortens to its label.
///
/// No status or hint lines: every state is carried by a control (the dot,
/// the pill, a greyed key), per the app's no-helper-text rule.
struct KeyboardRootView: View {
    let onMicPress: () -> Void
    let onAssistPress: () -> Void
    /// The host's background-session heartbeat; nil when there isn't one.
    let session: KeyboardBridge.SessionState?
    /// Recent mic levels, oldest first, while a recording is in flight.
    /// Observed by the meter alone, so the 20 Hz updates redraw the bars
    /// and nothing else.
    var levels = KeyboardLevels()
    /// Why the last request produced no text, briefly. Shown in the Paste
    /// chip's place for a few seconds.
    let notice: String?
    let onStop: () -> Void
    let onCancel: () -> Void
    /// Release the warm mic now (the mic's context menu).
    let onEndSession: () -> Void
    let onUndo: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    /// True when the host device + iOS Settings combination can
    /// actually run Apple Intelligence. When false we hide the
    /// Assist button entirely — older iPhones (pre-15 Pro) will
    /// never get an Assist that works, so dangling it disabled is
    /// worse than hiding it. The Settings screen in the host app
    /// explains why.
    let assistSupported: Bool
    /// True when there's a selection, or freshly copied text, for Assist
    /// to rewrite. When false the Assist key greys out and a tap shakes it
    /// rather than launching the host with nothing to act on.
    let canAssist: Bool
    /// Backspace uses press / release callbacks rather than a single
    /// tap action so the controller can run a hold-to-repeat timer
    /// (char delete after a short delay, escalating to word delete
    /// after a longer hold).
    let onBackspacePress: () -> Void
    let onBackspaceRelease: () -> Void
    let canUndo: Bool
    /// True when the system clipboard has a string to paste. Drives
    /// the Paste chip's enabled state.
    let canPaste: Bool
    /// Text the keyboard renders in the Paste chip. Sourced from the
    /// host's last-dictation snapshot via the App Group; `nil` when the
    /// system clipboard has been overwritten by another app since the
    /// host wrote (or the host hasn't transcribed yet on this device).
    /// We never read `UIPasteboard.general.string` for this — that would
    /// trip iOS's "Pasted from X" toast / permission prompt.
    let pastePreview: String?
    /// Tap action for the Paste chip. Reads from `UIPasteboard.general`
    /// and inserts via the text document proxy — see
    /// `KeyboardViewController.pasteFromClipboard`.
    let onPaste: () -> Void
    /// Show the globe key. Apple requires it whenever
    /// `needsInputModeSwitchKey` is true (devices without the system's own
    /// keyboard switcher under the keyboard).
    var showsNextKeyboard: Bool = false
    var onNextKeyboard: () -> Void = {}

    /// The keyboard's height, set by the controller. Two rows plus a
    /// little padding.
    static let height: CGFloat = 116
    /// The widest the rows get on a big screen, as a centred band.
    static let bandWidth: CGFloat = 640

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when a greyed Assist key is tapped, to shake it.
    @State private var assistShakes = 0

    private enum Phase: Equatable { case idle, recording, working }

    private var phase: Phase {
        switch session?.phase {
        case .recording: .recording
        case .transcribing: .working
        default: .idle
        }
    }
    private var isAssist: Bool { phase != .idle && session?.mode == .assist }
    private var tint: Color { isAssist ? .dictatorAssist : .dictatorSpeak }
    private var micWarm: Bool { session?.phase == .ready }

    /// Sizes that change between the docked keyboard and the iPad's small
    /// floating one.
    private struct Metrics {
        var key: CGFloat
        var micWidth: CGFloat
        var returnWidth: CGFloat
        var deleteWidth: CGFloat
        var compactPaste: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // The iPad's floating keyboard is about 320pt wide; every
            // supported iPhone is 375pt or wider.
            let floating = width < 360
            let metrics = floating
                ? Metrics(key: 40, micWidth: 48, returnWidth: 64, deleteWidth: 44, compactPaste: true)
                : Metrics(key: 44, micWidth: width >= 600 ? 72 : 52, returnWidth: width >= 600 ? 96 : 84,
                          deleteWidth: width >= 600 ? 56 : 52, compactPaste: false)
            Group {
                if let fold = FoldGeometry.verticalFold(in: proxy),
                   fold.lowerBound >= 220, width - fold.upperBound >= 260 {
                    split(width: width, fold: fold, metrics: metrics)
                } else {
                    band(metrics: metrics)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: Self.bandWidth)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: width, height: proxy.size.height)
        }
        .background(Color(.secondarySystemBackground))
        .animation(motion, value: phase)
        .animation(motion, value: isAssist)
    }

    // MARK: - Layouts

    /// One band: both rows, the full width (capped by the caller).
    private func band(metrics: Metrics) -> some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 3) {
                HStack(spacing: 6) {
                    if phase == .idle {
                        undoKey(metrics)
                            .transition(pieceTransition)
                        pasteChip(metrics)
                            .transition(pieceTransition)
                        if assistSupported {
                            assistKey(metrics)
                                .transition(pieceTransition)
                        }
                    } else {
                        cancelKey(metrics)
                            .transition(pieceTransition)
                    }
                    micOrPill(metrics, idleWidth: metrics.micWidth)
                }
            }
            bottomRow(metrics, globe: true, returnAndDelete: true)
        }
    }

    /// A partly folded Duo: nothing on the crease. Undo and Paste under the
    /// left thumb, Assist and the (wider) mic under the right, with space on
    /// both halves.
    private func split(width: CGFloat, fold: ClosedRange<CGFloat>, metrics: Metrics) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                GlassEffectContainer(spacing: 3) {
                    HStack(spacing: 6) {
                        undoKey(metrics)
                        pasteChip(metrics)
                    }
                }
                bottomRow(metrics, globe: true, returnAndDelete: false)
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(width: fold.lowerBound)

            Color.clear.frame(width: fold.upperBound - fold.lowerBound)

            VStack(spacing: 8) {
                GlassEffectContainer(spacing: 3) {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if phase == .idle {
                            if assistSupported {
                                assistKey(metrics)
                                    .transition(pieceTransition)
                            }
                        } else {
                            cancelKey(metrics)
                                .transition(pieceTransition)
                        }
                        micOrPill(metrics, idleWidth: 120)
                    }
                }
                bottomRow(metrics, globe: false, returnAndDelete: true)
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(width: width - fold.upperBound)
        }
    }

    private func bottomRow(_ m: Metrics, globe: Bool, returnAndDelete: Bool) -> some View {
        // One container so the keys share a glass pass. Its spacing is
        // under the keys' gap, so they never blend into each other.
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: 6) {
                if globe && showsNextKeyboard {
                    iconKey("globe", label: "Next keyboard", width: m.key, height: m.key, action: onNextKeyboard)
                }
                spaceKey(m)
                if returnAndDelete {
                    returnKey(m)
                    backspaceKey(m)
                }
            }
        }
    }

    // MARK: - Top row pieces

    private func undoKey(_ m: Metrics) -> some View {
        iconKey("arrow.uturn.backward", label: "Undo", width: m.key, height: m.key, enabled: canUndo, action: onUndo)
            .glassEffectID("undo", in: glass)
    }

    /// The clipboard: a snippet of what Paste would insert when we know
    /// (Dictator wrote it), else just "Paste". Greyed when the clipboard is
    /// empty. Briefly shows why the last request produced no text instead.
    private func pasteChip(_ m: Metrics) -> some View {
        Button(action: onPaste) {
            HStack(spacing: 7) {
                if let notice, !m.compactPaste {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14, weight: .semibold))
                    Text(m.compactPaste ? "Paste" : pasteLabel)
                        .font(.footnote.weight(pastePreview == nil || m.compactPaste ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Fade the content, not the glass (`.opacity` doesn't reach a
            // glassEffect) to show there's nothing to paste.
            .foregroundStyle(canPaste ? Color.primary : Color.secondary.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: m.compactPaste ? .center : .leading)
            .frame(height: m.key)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canPaste)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .glassEffectID("paste", in: glass)
        .accessibilityLabel(pasteAccessibilityLabel)
    }

    private var pasteLabel: String {
        guard let pastePreview else { return "Paste" }
        let snippet = pastePreview
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? "Paste" : snippet
    }

    private var pasteAccessibilityLabel: String {
        if let notice { return notice }
        if let pastePreview { return "Paste: \(pastePreview)" }
        return "Paste"
    }

    /// Assist rewrites the highlighted text, or failing that what's freshly
    /// on the clipboard. With nothing to act on it greys out but stays
    /// tappable, and a tap shakes it — a true `.disabled()` button would
    /// leave the user prodding a dead control.
    private func assistKey(_ m: Metrics) -> some View {
        Button {
            if canAssist {
                onAssistPress()
            } else {
                assistShakes += 1
            }
        } label: {
            AssistGlyph()
                .fill(Color.dictatorAssist.opacity(canAssist ? 1 : 0.3))
                .frame(width: m.key * 0.43, height: m.key * 0.43)
                .frame(width: m.key, height: m.key)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: assistShakes) { content, x in
            content.offset(x: x)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-5, duration: 0.05)
                LinearKeyframe(5, duration: 0.08)
                LinearKeyframe(-3, duration: 0.07)
                LinearKeyframe(0, duration: 0.06)
            }
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("assist", in: glass)
        .accessibilityLabel("Assist")
        .accessibilityHint(canAssist ? "" : "Highlight or copy some text first")
    }

    private func cancelKey(_ m: Metrics) -> some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: m.key, height: m.key)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("cancel", in: glass)
        .accessibilityLabel(phase == .working ? "Cancel processing" : "Cancel recording")
    }

    /// The mic, stretched into the pill while recording or working. One
    /// glass piece throughout, so it morphs rather than swaps.
    private func micOrPill(_ m: Metrics, idleWidth: CGFloat) -> some View {
        Button(action: primaryAction) {
            HStack(spacing: 10) {
                switch phase {
                case .idle:
                    Image(systemName: "mic.fill")
                        .font(.system(size: m.key * 0.41, weight: .semibold))
                        .transition(.opacity)
                case .recording:
                    if isAssist {
                        AssistGlyph()
                            .frame(width: 18, height: 18)
                            .transition(.opacity)
                    }
                    LevelHistory(levels: levels, height: m.key * 0.5)
                        .frame(maxWidth: .infinity)
                        .transition(listeningTransition)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .transition(.opacity)
                case .working:
                    ProgressView()
                        .tint(.white)
                        .transition(.opacity)
                    Text(isAssist ? "Applying" : "Transcribing")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, phase == .idle ? 0 : 16)
            .frame(width: phase == .idle ? idleWidth : nil)
            .frame(maxWidth: phase == .idle ? nil : .infinity)
            .frame(height: m.key)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(primaryTint).interactive(), in: .capsule)
        .glassEffectID("primary", in: glass)
        // The warm-mic dot: the mic is open in the background and Dictate
        // records in place. Orange, like the system's own mic indicator.
        .overlay(alignment: .topTrailing) {
            if phase == .idle && micWarm {
                Circle()
                    .fill(.orange)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color(.secondarySystemBackground), lineWidth: 2))
                    .offset(x: 2, y: -2)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .contextMenu {
            if phase == .idle && micWarm {
                Button("Turn Off Mic", systemImage: "mic.slash", action: onEndSession)
            }
        }
        .accessibilityLabel(primaryLabel)
        .accessibilityActions {
            if phase == .idle && micWarm {
                Button("Turn off mic", action: onEndSession)
            }
        }
    }

    private var primaryTint: Color {
        switch phase {
        case .idle: .dictatorSpeak
        case .recording: tint
        case .working: tint.opacity(0.6)
        }
    }

    private var primaryLabel: String {
        switch phase {
        case .idle:
            if micWarm, let expiresAt = session?.expiresAt {
                return "Dictate. Mic ready until \(expiresAt.formatted(date: .omitted, time: .shortened))"
            }
            return micWarm ? "Dictate. Mic ready" : "Dictate"
        case .recording: return isAssist ? "Send and apply" : "Send"
        case .working: return isAssist ? "Applying" : "Transcribing"
        }
    }

    private func primaryAction() {
        switch phase {
        case .idle: onMicPress()
        case .recording: onStop()
        case .working: break
        }
    }

    // MARK: - Bottom row pieces

    private func spaceKey(_ m: Metrics) -> some View {
        Button(action: onSpace) {
            Text("space")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: m.key)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .accessibilityLabel("Space")
    }

    private func returnKey(_ m: Metrics) -> some View {
        Button(action: onReturn) {
            Text("return")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: m.returnWidth, height: m.key)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.accentColor).interactive(), in: .rect(cornerRadius: 10))
        .accessibilityLabel("Return")
    }

    /// Press-and-hold backspace: driven by a zero-duration long press so
    /// the controller can repeat-delete while the user holds. A tap still
    /// deletes one character, because the controller deletes on press.
    @State private var backspacePressed = false

    private func backspaceKey(_ m: Metrics) -> some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: m.deleteWidth, height: m.key)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
            .scaleEffect(backspacePressed ? 0.94 : 1)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: backspacePressed)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                // Tap completion is a no-op; the press edge already deleted.
            } onPressingChanged: { pressing in
                if pressing, !backspacePressed {
                    backspacePressed = true
                    onBackspacePress()
                } else if !pressing, backspacePressed {
                    backspacePressed = false
                    onBackspaceRelease()
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Backspace")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onBackspacePress()
                onBackspaceRelease()
            }
    }

    /// A square glass key with a symbol. Disabled keys fade their symbol,
    /// not the glass (`.opacity` doesn't affect a glassEffect).
    private func iconKey(
        _ symbol: String,
        label: String,
        width: CGFloat,
        height: CGFloat,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary.opacity(enabled ? 1 : 0.3))
                .frame(width: width, height: height)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .accessibilityLabel(label)
    }

    // MARK: - Motion

    /// The same soft spring as the Dictate screen's morph; with Reduce
    /// Motion the pieces simply cross-fade.
    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .bouncy(duration: 0.45, extraBounce: 0.06)
    }

    private var pieceTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.3, anchor: .trailing).combined(with: .opacity)
    }

    private var listeningTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .trailing).combined(with: .opacity)
    }
}

/// A scrolling meter of the last few mic levels, newest on the right, so the
/// user can see they're being heard while the app doing the hearing is out of
/// sight. Plain shapes driven by the controller's history rather than the
/// app's `Waveform`, whose canvas drew nothing inside the keyboard. Boosted
/// like `Waveform`: flat bars while someone is talking read worse than the
/// odd loud syllable touching the top. Bars are dropped from the left to fit
/// the width it's given.
private struct LevelHistory: View {
    let levels: KeyboardLevels
    var height: CGFloat = 22
    static let maxCount = 64

    var body: some View {
        GeometryReader { proxy in
            let count = max(4, min(Self.maxCount, Int((proxy.size.width + 2.5) / 5.5)))
            let recent = Array(levels.values.suffix(count))
            let padded = Array(repeating: Float(0), count: max(0, count - recent.count)) + recent
            HStack(spacing: 2.5) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .frame(width: 3, height: max(3, height * min(1, CGFloat(padded[index]) * 1.7)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.08), value: levels.values)
    }
}

/// The keyboard meter's recent levels, oldest first. A reference the
/// controller updates in place while recording, read only by
/// `LevelHistory`.
@MainActor
@Observable
final class KeyboardLevels {
    var values: [Float]

    init(_ values: [Float] = []) {
        self.values = values
    }
}
