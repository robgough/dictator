import SwiftUI

struct HUDView: View {
    @Environment(AppState.self) private var state
    @State private var deviceManager = AudioDeviceManager.shared
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // SwiftUI's `.thinMaterial` clips correctly against the rounded shape,
            // unlike a wrapped NSVisualEffectView which rasterises into the layer
            // before the clip is applied. macOS picks up the rounded alpha and
            // draws a window shadow that follows the pill outline.
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            StatusRow(icon: "selection.pin.in.out", title: "Reading selection", accent: .indigo)
        case .warmingUp(let isAssistant):
            // Bluetooth mics (AirPods, Beats, …) need 2–5 s for HFP profile
            // negotiation before AVAudioEngine actually starts producing
            // buffers. Surface that explicitly so the user doesn't think
            // they've been recording for the past few seconds.
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isAssistant ? Color.indigo : Color.accentColor)
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
                        .foregroundStyle(Color.indigo)
                        .font(.system(size: 18, weight: .semibold))
                } else {
                    RecordingDot()
                }
                Waveform(level: level, tint: isAssistant ? .indigo : .accentColor)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(isContinuation ? "Following up" : (isAssistant ? "Assistant" : "Listening"))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isAssistant ? Color.indigo : .primary)
                    Text(isContinuation
                         ? "Continuing the conversation"
                         : (isAssistant ? "Speak your instruction" : deviceManager.activeInputDeviceName()))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 180, alignment: .trailing)
            }
        case .transcribing:
            StatusRow(icon: "waveform.badge.magnifyingglass", title: "Transcribing", accent: .blue)
        case .formatting:
            StatusRow(icon: "sparkles", title: "Formatting", accent: .purple)
        case .fixingGrammar:
            StatusRow(icon: "text.badge.checkmark", title: "Tidying grammar", accent: .pink)
        case .restructuring:
            StatusRow(icon: "list.bullet.indent", title: "Structuring", accent: .teal)
        case .assisting:
            StatusRow(icon: "wand.and.stars", title: "Thinking", accent: .indigo)
        case .compacting:
            StatusRow(icon: "archivebox", title: "Summarising earlier turns", accent: .indigo)
        case .done(let text, let pasted, let note):
            HStack(spacing: 14) {
                Image(systemName: pasted ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, pasted ? Color.accentColor : .orange)
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
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .failed(let message):
            HStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
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
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .onAppear { pulse = true }
    }
}

private struct RecordingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .shadow(color: .accentColor.opacity(0.6), radius: on ? 10 : 2)
            .opacity(on ? 1 : 0.6)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
