import SwiftUI

// Literal RGB tints for the non-blue HUD accents. We deliberately don't use
// SwiftUI's semantic colours (`.indigo`, `.purple`, `.pink`, `.teal`,
// `.orange`) here: those are dynamic and re-resolve under the visual-effect
// view's vibrancy appearance, which itself shifts with the window content
// behind the HUD — so otherwise the icons and status text would drift in
// colour as the user moved the HUD over different apps. The HUD's blue
// reuses `Color.brandBlue` (defined in BrandColors.swift).
private extension Color {
    static let hudIndigo = Color(red: 0.369, green: 0.361, blue: 0.902) // ~#5E5CE6
    static let hudPurple = Color(red: 0.749, green: 0.353, blue: 0.949) // ~#BF5AF2
    static let hudPink   = Color(red: 1.0,   green: 0.216, blue: 0.373) // ~#FF375F
    static let hudTeal   = Color(red: 0.392, green: 0.824, blue: 1.0)   // ~#64D2FF
    static let hudOrange = Color(red: 1.0,   green: 0.624, blue: 0.039) // ~#FF9F0A
}

struct HUDView: View {
    @Environment(AppState.self) private var state
    @State private var deviceManager = AudioDeviceManager.shared
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `.regularMaterial` (vs the thinner variant) blocks more of the
            // underlying window so the waveform doesn't desaturate when the
            // HUD floats over a dark or colourful background. SwiftUI clips
            // the material to the rounded shape, so macOS draws the window
            // shadow following the pill outline.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if hovering && state.pipeline.state.canCancel {
                    Button {
                        state.pipeline.cancelInFlight()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.snappy(duration: 0.18), value: hovering)
            .animation(.snappy(duration: 0.25), value: stateKey)
            .onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        switch state.pipeline.state {
        case .idle:
            EmptyView()
        case .capturingSelection:
            StatusRow(icon: "selection.pin.in.out", title: "Reading selection", accent: .hudIndigo)
        case .warmingUp(let isAssistant):
            // Bluetooth mics (AirPods, Beats, …) need 2–5 s for HFP profile
            // negotiation before AVAudioEngine actually starts producing
            // buffers. Surface that explicitly so the user doesn't think
            // they've been recording for the past few seconds.
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isAssistant ? Color.hudIndigo : Color.brandBlue)
                    .font(.system(size: 22, weight: .semibold))
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting microphone")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(deviceManager.activeInputDeviceName())
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProgressView()
                    .controlSize(.small)
            }
        case .recording(let level, let isAssistant):
            let isContinuation = isAssistant && state.pipeline.nextAssistantIsContinuation
            HStack(spacing: 16) {
                if isAssistant {
                    Image(systemName: isContinuation ? "bubble.left.and.bubble.right.fill" : "wand.and.stars")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.hudIndigo)
                        .font(.system(size: 18, weight: .semibold))
                } else {
                    RecordingDot()
                }
                Waveform(level: level, tint: isAssistant ? .hudIndigo : .brandBlue)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(isContinuation ? "Following up" : (isAssistant ? "Assistant" : "Listening"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isAssistant ? Color.hudIndigo : .primary)
                    Text(isContinuation
                         ? "Continuing the conversation"
                         : (isAssistant ? "Speak your instruction" : deviceManager.activeInputDeviceName()))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Mode chip — dictation only. Modes don't apply to
                    // Assistant Mode (separate flow, separate prompt). The
                    // "Tab → next" suffix only renders when Tab cycling will
                    // actually work — i.e. when Accessibility is granted so
                    // the CGEventTap can swallow Tab before it inserts a tab
                    // character into the focused app. Without AX we'd be
                    // promising a feature we can't deliver.
                    if !isAssistant {
                        let canCycle = TextInjector.hasAccessibilityPermission()
                        ModeChip(
                            name: state.pipeline.currentMode.name,
                            nextName: canCycle ? state.pipeline.nextCycleMode?.name : nil
                        )
                    }
                }
                .frame(maxWidth: 200, alignment: .trailing)
            }
        case .transcribing:
            StatusRow(icon: "waveform.badge.magnifyingglass", title: "Transcribing", accent: .brandBlue)
        case .formatting:
            StatusRow(icon: "sparkles", title: "Formatting", accent: .hudPurple)
        case .fixingGrammar:
            StatusRow(icon: "text.badge.checkmark", title: "Tidying grammar", accent: .hudPink)
        case .restructuring:
            StatusRow(icon: "list.bullet.indent", title: "Structuring", accent: .hudTeal)
        case .assisting:
            StatusRow(icon: "wand.and.stars", title: "Thinking", accent: .hudIndigo)
        case .compacting:
            StatusRow(icon: "archivebox", title: "Summarising earlier turns", accent: .hudIndigo)
        case .done(let text, let pasted, let note):
            HStack(spacing: 14) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, pasted ? Color.brandBlue : Color.hudOrange)
                    .font(.system(size: 22, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .lineLimit(note == nil ? 2 : 1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                    if let note {
                        Text(note)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.hudOrange)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.hudOrange)
                    .font(.system(size: 22))
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stateKey: String {
        switch state.pipeline.state {
        case .idle: "idle"
        case .capturingSelection: "capturingSelection"
        case .warmingUp: "warmingUp"
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .formatting: "formatting"
        case .fixingGrammar: "fixingGrammar"
        case .restructuring: "restructuring"
        case .assisting: "assisting"
        case .compacting: "compacting"
        case .done: "done"
        case .failed: "failed"
        }
    }
}

private struct StatusRow: View {
    let icon: String
    let title: String
    let accent: Color
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
                .font(.system(size: 22, weight: .semibold))
                .scaleEffect(pulse ? 1.08 : 0.96)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                // Escape-cancel discoverability hint. Surfaced on every
                // "waiting" state — same set the EscapeCancelMonitor
                // listens on — so when something runs slow (or wedges)
                // the user already knows how to bail.
                Text("Press Esc to cancel")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .onAppear { pulse = true }
    }
}

/// Compact pill that names the active dictation mode, plus a "Tab → <next>"
/// suffix when the cycle has more than one entry. Renders inline in the HUD's
/// trailing column during `.recording` (dictation flow only).
private struct ModeChip: View {
    let name: String
    let nextName: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.brandBlue)
            if let nextName {
                Text("⇥")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                Text(nextName)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.brandBlue.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.brandBlue.opacity(0.25), lineWidth: 0.5)
        )
        .padding(.top, 1)
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.brandBlue)
            .frame(width: 10, height: 10)
            .shadow(color: Color.brandBlue.opacity(0.6), radius: on ? 10 : 2)
            .opacity(on ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
