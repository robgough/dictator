import SwiftUI
import AppKit

/// Renders one meeting. The three modes (live recording, processing,
/// ready) all share a header and switch the body underneath.
struct MeetingDetailView: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    @State private var titleDraft: String = ""
    @State private var transcriptCache: MeetingTranscript?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            titleDraft = session.meta.title
            reloadTranscriptIfNeeded()
        }
        .onChange(of: session.meta.title) { _, new in titleDraft = new }
        .onChange(of: session.state) { _, _ in reloadTranscriptIfNeeded() }
        // When the user picks a different meeting in the sidebar SwiftUI
        // reuses this view instance and just swaps the bound session.
        // `@State` (titleDraft / transcriptCache) survives the swap, so
        // without this onChange both stay stuck on the previous meeting's
        // values — the title happens to update via its own onChange, but
        // the transcript would silently keep showing the old one.
        .onChange(of: session.id) { _, _ in
            titleDraft = session.meta.title
            transcriptCache = nil
            reloadTranscriptIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $titleDraft, onCommit: {
                    session.rename(to: titleDraft)
                })
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statePill
        }
    }

    private var headerSubtitle: String {
        let date = Self.dateFormatter.string(from: session.meta.createdAt)
        if session.meta.durationSeconds > 0 {
            return "\(date) · \(Self.formatDuration(session.meta.durationSeconds))"
        }
        return date
    }

    private var statePill: some View {
        Group {
            switch session.state {
            case .idle, .ready:
                EmptyView()
            case .warmingUp:
                ProcessingPill(text: "Warming up…", color: .orange)
            case .recording(let elapsed, _, _):
                ProcessingPill(text: "Recording · \(Self.formatDuration(elapsed))", color: .red)
            case .stopping:
                ProcessingPill(text: "Finalising…", color: .orange)
            case .importing(let p):
                ProcessingPill(text: "Importing audio · \(Int(p * 100))%", color: .blue)
            case .captured:
                ProcessingPill(text: "Ready to process", color: .gray)
            case .loadingASR(let p):
                ProcessingPill(text: "Loading ASR · \(Int(p * 100))%", color: .blue)
            case .transcribingMic(let p):
                ProcessingPill(text: "Transcribing mic · \(Int(p * 100))%", color: .blue)
            case .transcribingSystem(let p):
                ProcessingPill(text: "Transcribing remote · \(Int(p * 100))%", color: .blue)
            case .loadingDiarizer(let p):
                ProcessingPill(text: "Loading speakers · \(Int(p * 100))%", color: .blue)
            case .diarizing:
                ProcessingPill(text: "Identifying speakers…", color: .blue)
            case .merging:
                ProcessingPill(text: "Writing transcript…", color: .blue)
            case .summarising:
                ProcessingPill(text: "Summarising…", color: .purple)
            case .failed:
                ProcessingPill(text: "Failed", color: .red)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .warmingUp, .stopping:
            LiveRecordingView(session: session, isWarming: true)
        case .recording:
            LiveRecordingView(session: session, isWarming: false)
        case .importing, .loadingASR, .transcribingMic, .transcribingSystem,
             .loadingDiarizer, .diarizing, .merging:
            ProcessingPane(session: session)
        case .summarising:
            // The transcript is already on disk by the time we're
            // summarising — keep it visible so the user can read while
            // the LLM works. The SummaryPanel inside TranscriptView
            // renders its own "Summarising…" placeholder.
            TranscriptView(meta: session.meta, transcript: transcriptCache, session: session)
        case .captured:
            VStack(spacing: 12) {
                Text("Recording saved. The transcript hasn't been generated yet.")
                    .foregroundStyle(.secondary)
                Button("Process now") {
                    Task { await session.runProcessor(parakeetModelID: state.settings.parakeetModelID) }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if message.contains("System Audio Recording") {
                    Button("Open System Settings") {
                        AudioRecordingPermission.openSystemSettings()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        case .idle, .ready:
            TranscriptView(meta: session.meta, transcript: transcriptCache, session: session)
        }
    }

    private func reloadTranscriptIfNeeded() {
        // Only clear the cache when the new state could regenerate the
        // transcript on disk — that's the transcribe / diarize / merge
        // path. Other transitions (notably `.summarising`) leave the
        // transcript file untouched, so keeping it on screen avoids a
        // jarring blank flash mid-regenerate.
        switch session.state {
        case .ready:
            transcriptCache = MeetingStorage.readTranscript(for: session.id)
        case .summarising:
            // The summary pass reads transcript.json without touching it.
            // Keep whatever's already rendered visible.
            return
        case .loadingASR, .transcribingMic, .transcribingSystem,
             .loadingDiarizer, .diarizing, .merging:
            if transcriptCache != nil { transcriptCache = nil }
        default:
            if transcriptCache != nil { transcriptCache = nil }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private struct ProcessingPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

/// Live-recording body: timer + two stacked level meters + stop button.
struct LiveRecordingView: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    let isWarming: Bool

    var body: some View {
        VStack(spacing: 20) {
            timerView

            // Capture warnings (mic and / or system) — surfaced when a
            // recorder fails to deliver buffers within its bring-up
            // watchdog window. Sits above the meters so the user
            // notices it instead of staring at a flat bar. Dismissible
            // per source; the dismissal is UI-only and resets next
            // recording.
            if !session.captureWarnings.isEmpty {
                VStack(spacing: 8) {
                    ForEach(session.captureWarnings) { warning in
                        CaptureWarningBanner(message: warning.message) {
                            session.dismissCaptureWarning(source: warning.source)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                LabeledWaveform(label: "Mic (Me)", level: levels.mic, tint: .accentColor)
                LabeledWaveform(label: "System (Other)", level: levels.system, tint: .indigo)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            // Draft transcript pane. Only present while a live transcriber
            // exists on the session — the post-capture / processing / ready
            // states render the canonical transcript via TranscriptView and
            // never see this pane.
            if let transcriber = session.liveTranscriber {
                LiveTranscriptPane(transcriber: transcriber)
            }

            Button(role: .destructive) {
                Task {
                    await session.stopRecording(parakeetModelID: state.settings.parakeetModelID)
                }
            } label: {
                Label("Stop recording", systemImage: "stop.circle.fill")
                    .frame(minWidth: 160)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(isWarming)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var timerView: some View {
        Text(timerText)
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.primary)
    }

    private var timerText: String {
        if case .recording(let elapsed, _, _) = session.state {
            return Self.format(elapsed)
        }
        return "00:00"
    }

    private var levels: (mic: Float, system: Float) {
        if case .recording(_, let mic, let sys) = session.state {
            return (mic, sys)
        }
        return (0, 0)
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct LabeledWaveform: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Waveform(level: level, tint: tint)
        }
    }
}

private struct ProcessingPane: View {
    @Bindable var session: MeetingSession

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .frame(maxWidth: 480)
            Text(stageLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressValue: Double {
        switch session.state {
        case .importing(let p), .loadingASR(let p), .transcribingMic(let p),
             .transcribingSystem(let p), .loadingDiarizer(let p), .diarizing(let p):
            return p
        case .merging: return 0.95
        default: return 0
        }
    }

    private var stageLabel: String {
        switch session.state {
        case .importing(let p): return "Importing audio (\(Int(p * 100))%)…"
        case .loadingASR: return "Loading transcription model…"
        case .transcribingMic: return "Transcribing your microphone track…"
        case .transcribingSystem: return "Transcribing the system audio track…"
        case .loadingDiarizer: return "Loading speaker-identification model…"
        case .diarizing: return "Identifying who spoke when…"
        case .merging: return "Writing the transcript…"
        default: return ""
        }
    }
}

/// Muted yellow-orange warning pill, used by `LiveRecordingView` to
/// surface capture-side issues (mic recorder isn't getting buffers, or
/// the CATap recorder hasn't seen any system audio yet — usually a
/// silent call or output routed off the default device). Matches the
/// shape of the permission banner on `MeetingsEmptyState` — same
/// rounded-rect background, same `.orange.opacity(0.12)` fill — with
/// an `xmark` dismiss so the user can hide a warning they already know
/// about.
private struct CaptureWarningBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

/// Live-recording draft transcript. Fills in chunk by chunk while the meeting
/// records; the canonical, diarized transcript replaces it as soon as the
/// post-capture processor finishes. No speaker attribution in this view —
/// that's the post-pass's job. Empty state shows a "Listening…" placeholder
/// so the user can see the pane wired up even before the first chunk lands.
private struct LiveTranscriptPane: View {
    @Bindable var transcriber: MeetingLiveTranscriber

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if transcriber.interimText.isEmpty {
                        Text("Listening…")
                            .italic()
                            .foregroundStyle(.tertiary)
                    } else {
                        // The trailing bottomAnchor view is what the
                        // ScrollViewReader pins to as new chunks land —
                        // gives us the auto-scroll-to-bottom behaviour
                        // without any manual scroll-offset math.
                        Text(transcriber.interimText)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(14)
            }
            .frame(maxHeight: 240)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            .onChange(of: transcriber.interimText) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "live-transcript-bottom"
}
