import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DictatorLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        DictationLiveActivity()
    }
}

/// Lock screen + Dynamic Island for a held microphone. Three phases, and in
/// each one the button that matters is right there: Dictate when the mic is
/// warm, Stop while recording, and the mic-off button always.
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseIcon(phase: context.state.phase)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    EndButton()
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(context.state.phase))
                            .font(.headline)
                        Subtitle(state: context.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ToggleButton(phase: context.state.phase)
                        .padding(.top, 4)
                }
            } compactLeading: {
                PhaseIcon(phase: context.state.phase)
            } compactTrailing: {
                CompactTrailing(state: context.state)
            } minimal: {
                PhaseIcon(phase: context.state.phase)
            }
        }
    }
}

private func title(_ phase: DictationActivityAttributes.ContentState.Phase) -> String {
    switch phase {
    case .ready: "Ready to dictate"
    case .recording: "Listening"
    case .transcribing: "Transcribing"
    }
}

private struct LockScreenView: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            PhaseIcon(phase: state.phase)
                .font(.title)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title(state.phase))
                    .font(.headline)
                Subtitle(state: state)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if state.phase != .transcribing {
                ToggleButton(phase: state.phase)
                    .fixedSize()
            }
            EndButton()
        }
    }
}

private struct Subtitle: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            if let started = state.recordingStartedAt {
                Text(started, style: .timer)
            } else {
                Text("Speak now")
            }
        case .transcribing:
            Text("Your text goes to the clipboard")
        case .ready:
            if let snippet = state.lastSnippet {
                Text("Copied: \(snippet)…")
            } else if let expiresAt = state.expiresAt {
                Text("Not recording · ends at \(expiresAt, style: .time)")
            } else {
                Text("Not recording until you tap Dictate")
            }
        }
    }
}

private struct CompactTrailing: View {
    let state: DictationActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            if let started = state.recordingStartedAt {
                Text(started, style: .timer)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(.red)
            }
        case .transcribing:
            ProgressView().tint(.orange)
        case .ready:
            if let expiresAt = state.expiresAt {
                Text(timerInterval: Date()...max(Date(), expiresAt), countsDown: true)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PhaseIcon: View {
    let phase: DictationActivityAttributes.ContentState.Phase

    var body: some View {
        switch phase {
        case .ready:
            Image(systemName: "mic").foregroundStyle(.orange)
        case .recording:
            Image(systemName: "waveform").foregroundStyle(.red)
        case .transcribing:
            Image(systemName: "text.bubble").foregroundStyle(.orange)
        }
    }
}

private struct ToggleButton: View {
    let phase: DictationActivityAttributes.ContentState.Phase

    var body: some View {
        Button(intent: ToggleDictationIntent()) {
            Label(phase == .recording ? "Stop" : "Dictate",
                  systemImage: phase == .recording ? "stop.fill" : "mic.fill")
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .tint(phase == .recording ? .red : .orange)
        .disabled(phase == .transcribing)
    }
}

private struct EndButton: View {
    var body: some View {
        Button(intent: EndDictationSessionIntent()) {
            Image(systemName: "mic.slash.fill")
                .font(.callout.weight(.semibold))
        }
        .tint(.gray)
        .accessibilityLabel("End keyboard dictation")
    }
}
