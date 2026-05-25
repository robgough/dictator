import SwiftUI

/// The keyboard's SwiftUI layout. Two big buttons (red mic, purple
/// assist) plus a tiny secondary row with Undo / Return / Backspace.
/// When the host is mid-recording or mid-transcribing for a keyboard
/// session, the whole top area flips to an in-flight view with a Stop
/// button + level pulse + status caption, so the user can drive
/// Dictator entirely from the keyboard after switching back to their
/// original app.
struct KeyboardRootView: View {
    let onMicPress: () -> Void
    let onAssistPress: () -> Void
    let onStop: () -> Void
    let onUndo: () -> Void
    let onSpace: () -> Void
    let onReturn: () -> Void
    /// True when there's text before the cursor for assist to
    /// transform. When false the Assist button greys out — tapping
    /// it with an empty field would launch the host with nothing to
    /// act on, which silently does nothing and looks broken.
    let canAssist: Bool
    /// Backspace uses press / release callbacks rather than a single
    /// tap action so the controller can run a hold-to-repeat timer
    /// (char delete after a short delay, escalating to word delete
    /// after a longer hold).
    let onBackspacePress: () -> Void
    let onBackspaceRelease: () -> Void
    let canUndo: Bool
    /// Non-nil while a keyboard-driven recording / transcription is
    /// in flight. Drives the in-flight UI.
    let hostState: KeyboardBridge.HostState?
    /// Optional model-readiness hint published by the host. Drives a
    /// small chip above the primary buttons so the user can gauge
    /// how long the next dictation will take before tapping.
    let modelReadiness: KeyboardBridge.ModelReadiness?

    var body: some View {
        VStack(spacing: 12) {
            if let state = hostState {
                inFlightContent(state)
            } else {
                idleContent
            }
            secondaryRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Idle (no in-flight session)

    @ViewBuilder
    private var idleContent: some View {
        if let readiness = modelReadiness {
            modelReadinessChip(readiness)
        }

        HStack(spacing: 24) {
            primaryButton(
                tint: .red,
                icon: "mic.fill",
                label: "Dictate",
                action: onMicPress,
                enabled: true
            )
            primaryButton(
                tint: .purple,
                icon: "wand.and.stars",
                label: "Assist",
                action: onAssistPress,
                enabled: canAssist
            )
        }

        Text("Tap a button — Dictator opens, you talk, the result lands here when you come back.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }

    /// Small chip above the primary buttons mirroring the in-app
    /// model status pill — same terminology ("Model loaded" vs
    /// "Model ready") and same dot colours (green / secondary) so
    /// the two surfaces read as one. The keyboard adds a red "not
    /// downloaded" state since the user might tap into a field
    /// before they've ever opened the host to download the model;
    /// the in-app pill doesn't need this because the host swaps the
    /// whole UI to a download CTA in that case.
    ///
    /// We trust the bridge's `loaded` flag. The host writes
    /// `loaded: false` on every cold launch and `loaded: true` once
    /// prewarm or first transcribe completes. The keyboard re-reads
    /// the bridge on every lifecycle event, so any stale claim
    /// self-corrects on the next host write.
    @ViewBuilder
    private func modelReadinessChip(_ readiness: KeyboardBridge.ModelReadiness) -> some View {
        let (color, text): (Color, String) = {
            switch readiness.diskStatus {
            case .notDownloaded:
                return (.red, "Model not downloaded")
            case .downloaded:
                // Three visually-distinct states: green for in-memory,
                // orange for on-disk-but-needs-loading, red for not
                // present. "Unloaded" reads more clearly than the
                // earlier "ready" — readiness implied the model could
                // dictate immediately, which it can't without warmup.
                if readiness.loaded {
                    return (.green, "Model loaded")
                } else {
                    return (.orange, "Model unloaded")
                }
            }
        }()
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color(.tertiarySystemBackground))
        )
    }

    // MARK: - In flight (host is recording / transcribing)

    @ViewBuilder
    private func inFlightContent(_ state: KeyboardBridge.HostState) -> some View {
        // Big Stop button. Level pulse around it scales with the
        // host's last-published RMS so the user gets the same "yes
        // I'm hearing you" feedback the main app shows. A rotating
        // dashed ring sits outside the button face — the pulse is
        // too soft to read under a thumb, so the spinning ring is
        // the primary "yes, you're being heard" cue. During the
        // transcribing phase the icon flips to an hourglass and the
        // button disables until the result lands.
        let isTranscribing = state.phase == .transcribing
        let label: String = switch state.phase {
        case .warmingUp: "Warming up…"
        case .recording: "Recording — tap to stop"
        case .transcribing: "Transcribing…"
        }

        ZStack {
            Circle()
                .fill(Color.red.opacity(0.18))
                .frame(
                    width: 100 + CGFloat(state.level) * 40,
                    height: 100 + CGFloat(state.level) * 40
                )
                .animation(.easeOut(duration: 0.1), value: state.level)
            if !isTranscribing {
                ActiveListeningRing(tint: .red, diameter: 126, lineWidth: 3)
            }
            Button(action: onStop) {
                Circle()
                    .fill(.red)
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: isTranscribing ? "hourglass" : "stop.fill")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .opacity(isTranscribing ? 0.6 : 1)
        }
        .frame(height: 140)

        Text(label)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
    }

    // MARK: - Secondary row

    @ViewBuilder
    private var secondaryRow: some View {
        HStack(spacing: 10) {
            secondaryButton(
                icon: "arrow.uturn.backward",
                label: "Undo",
                action: onUndo,
                enabled: canUndo
            )
            spaceBarButton
            secondaryButton(
                icon: "return",
                label: "Return",
                action: onReturn,
                enabled: true
            )
            backspaceButton
        }
        .padding(.horizontal, 12)
    }

    /// Wide space-bar tile that fills the gap between Undo and
    /// Return. Width-flex via `maxWidth: .infinity` so the fixed
    /// 60 pt tiles on either side stay put and the spacebar
    /// absorbs the remaining row.
    private var spaceBarButton: some View {
        Button(action: onSpace) {
            Text("space")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Space")
    }

    // MARK: - Backspace (tap = one char, hold = repeat)

    /// Press-and-hold backspace. Same visual shape as the other
    /// secondary tiles but driven by a long-press gesture so the
    /// controller can repeat-delete while the user holds. Tap-only
    /// users get a single delete on press-then-quick-release because
    /// the controller fires `deleteBackward()` immediately on press.
    @State private var backspacePressed = false

    private var backspaceButton: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 60, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .scaleEffect(backspacePressed ? 0.95 : 1)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: backspacePressed)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) {
                // Tap-completion handler; press / release fire via
                // onPressingChanged so the repeat timer can engage.
            } onPressingChanged: { pressing in
                if pressing, !backspacePressed {
                    backspacePressed = true
                    onBackspacePress()
                } else if !pressing, backspacePressed {
                    backspacePressed = false
                    onBackspaceRelease()
                }
            }
            .accessibilityLabel("Backspace")
    }

    // MARK: - Building blocks

    private func primaryButton(
        tint: Color,
        icon: String,
        label: String,
        action: @escaping () -> Void,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// Icon-only tile. The previous label-and-text layout was
    /// wrapping "Backspace" mid-word on narrower iPhones; this
    /// version drops the text (still readable from the icon) and
    /// bumps the vertical size to a comfortable tap target. The
    /// `label` parameter is retained for VoiceOver via
    /// `accessibilityLabel` so screen-reader users get the same
    /// affordance.
    private func secondaryButton(
        icon: String,
        label: String,
        action: @escaping () -> Void,
        enabled: Bool
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 60, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// Rotating dashed listening ring — duplicated from the main app
/// because the keyboard extension is a separate Swift module and the
/// helper isn't worth wiring through `project.yml` as a shared file
/// for ~25 lines. Keep in sync with the version in `ContentView.swift`.
///
/// Driven by `TimelineView(.animation)` so the rotation is purely a
/// function of `Date()` and survives view re-composition without the
/// `@State` + `repeatForever` desync footgun.
struct ActiveListeningRing: View {
    let tint: Color
    let diameter: CGFloat
    let lineWidth: CGFloat
    let period: Double

    init(tint: Color, diameter: CGFloat, lineWidth: CGFloat = 3, period: Double = 4) {
        self.tint = tint
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.period = period
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let rotation = (elapsed.truncatingRemainder(dividingBy: period) / period) * 360
            Circle()
                .strokeBorder(
                    tint,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        dash: [6, 10]
                    )
                )
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(rotation))
        }
    }
}
