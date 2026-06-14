import SwiftUI
import AppKit
import QuickLook

/// Renders one meeting. The three modes (live recording, processing,
/// ready) all share a header and switch the body underneath.
struct MeetingDetailView: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    @State private var titleDraft: String = ""
    @State private var transcriptCache: MeetingTranscript?
    @State private var titleHovered = false
    /// Whether the trailing Details inspector is showing. Remembered across
    /// launches; only takes effect for finished meetings (see `canShowInspector`).
    @AppStorage("meetingsInspectorVisible") private var inspectorVisible = true

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            // The live-recording view is a fill-the-height two-column layout
            // (notes on the left, controls + transcript on the right) with its
            // own internal scrolling, so it bypasses the outer ScrollView the
            // processing / ready states use.
            if session.state.isLive {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if showsTranscript {
                // TranscriptView owns its own ScrollView so its tab picker
                // stays fixed and the playback dock floats over the content —
                // wrapping it in another ScrollView would break both.
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    content
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
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
        // A speaker merge rewrites transcript.json in place without a state
        // transition — refresh the cache so the new attribution shows.
        .onChange(of: session.transcriptRevision) { _, _ in
            transcriptCache = MeetingStorage.readTranscript(for: session.id)
        }
        // Trailing Details inspector — metadata, speaker editing, and the
        // on-demand notes control. Only for finished meetings, so it never
        // squeezes the fixed-width live-recording layout.
        .inspector(isPresented: inspectorBinding) {
            MeetingInspector(session: session)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
    }

    /// True for finished meetings, where the Details inspector and document
    /// actions make sense. Hidden while live / processing / failed so the
    /// inspector can't appear and squeeze the live two-column layout.
    private var canShowInspector: Bool {
        switch session.state {
        case .ready, .idle, .summarising: return true
        default: return false
        }
    }

    /// Drives `.inspector`: the remembered preference, gated on the meeting
    /// actually being a finished one. (Live recordings show the evidence as an
    /// in-window column, not an inspector — see `MeetingLiveColumns`.)
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorVisible && canShowInspector },
            set: { inspectorVisible = $0 }
        )
    }

    /// States whose content is the transcript page (which manages its own
    /// scrolling); the rest use the plain outer ScrollView.
    private var showsTranscript: Bool {
        switch session.state {
        case .summarising, .idle, .ready: return true
        default: return false
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
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(titleHovered ? Color.secondary.opacity(0.12) : .clear)
                )
                .onHover { titleHovered = $0 }
                .help("Click to rename this meeting.")
                .padding(.horizontal, -6)
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
        var parts = [date]
        if session.meta.durationSeconds > 0 {
            parts.append(Self.formatDuration(session.meta.durationSeconds))
        }
        // Acknowledge a system-only capture (you listened, didn't speak) so the
        // absence of a "Me" speaker reads as intentional, not broken.
        if !session.state.isLive,
           session.meta.source == .live,
           session.meta.audioFiles.mic == nil {
            parts.append("Listen-only")
        }
        return parts.joined(separator: " · ")
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
                ProcessingPill(text: "Writing notes…", color: .purple)
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
            // writing notes — keep it visible so the user can read while
            // the LLM works. The NotesPanel inside TranscriptView
            // renders its own "Writing notes…" placeholder.
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
                    .font(.system(.largeTitle))
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
        // Bespoke chip: its `color` varies across the full processing palette
        // (orange / red / blue / purple / gray), which the kit's fixed tone set
        // can't express — so it carries its own tint while sharing the kit's
        // Liquid Glass capsule so it floats consistently with the other pills.
        Text(text)
            .meetingGlassPill(tint: color)
    }
}

/// Live-recording body. A persistent status bar (timer, level meters, notes
/// style, Stop) sits above the work area: three columns — the user's **Pad**,
/// the **Live notes**, and the **Coach** (metrics + key points + opportunities)
/// — plus a collapsible right **sidebar** holding the live evidence (the latest
/// shared-screen frame over the running transcript). The columns fold 3 → 2 → 1
/// as the window narrows; every column and the sidebar scroll on their own.
struct LiveRecordingView: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    let isWarming: Bool
    /// Evidence column (shared screen + transcript) visibility, toggled from the
    /// toolbar. In-window, not a native inspector — the inspector kept breaking
    /// the detail's top safe area on relayout during a live recording.
    @AppStorage("meetingLiveEvidenceVisible") private var showEvidence = true

    var body: some View {
        // Same shape as the (inspector-compatible) TranscriptView: a plain VStack
        // with the fixed bits on top and the filling content below, the whole
        // thing pinned topLeading. No GeometryReader (it fought the inspector's
        // relayout). The status bar is `fixedSize` vertically so the VStack hands
        // the columns the *remaining* height instead of the full height, which is
        // what was overflowing and pushing the bar up under the toolbar.
        VStack(spacing: 12) {
            LiveStatusBar(session: session, isWarming: isWarming, onStop: performStop)
                .fixedSize(horizontal: false, vertical: true)

            if !session.captureWarnings.isEmpty {
                VStack(spacing: 8) {
                    ForEach(session.captureWarnings) { warning in
                        CaptureWarningBanner(message: warning.message) {
                            session.dismissCaptureWarning(source: warning.source)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            MeetingLiveColumns(session: session, showEvidence: showEvidence)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func performStop() {
        Task {
            await session.stopRecording(parakeetModelID: state.settings.parakeetModelID)
        }
    }
}

/// Always-visible top bar for a live recording. Holds the things that must
/// never scroll out of reach: the elapsed timer, the You / Other side meters
/// with their "heard" confirmation, the notes-style picker, and the deliberate
/// Stop control (keeping the first-click catcher so Stop works even when the
/// window is inactive).
private struct LiveStatusBar: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession
    let isWarming: Bool
    let onStop: () -> Void

    var body: some View {
        // A single non-wrapping row would impose a ~700pt minimum width on the
        // detail pane, which — with the sidebar and inspector also taking room —
        // forces the whole window content wider than the window and overflows
        // both sides. ViewThatFits picks the densest row that fits: full → drop
        // the notes-style picker → drop the meters. Timer + Stop always remain.
        ViewThatFits(in: .horizontal) {
            bar(showMeters: true, showPicker: true)
            bar(showMeters: true, showPicker: false)
            bar(showMeters: false, showPicker: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .meetingGlassControl(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func bar(showMeters: Bool, showPicker: Bool) -> some View {
        HStack(alignment: .center, spacing: 16) {
            timerView
            if showMeters {
                Divider().frame(height: 22)
                HStack(alignment: .center, spacing: 14) {
                    LabeledWaveform(label: "You", level: levels.mic, tint: .accentColor, heard: session.micHeard)
                        .frame(width: 110)
                    LabeledWaveform(label: "Other side", level: levels.system, tint: .indigo, heard: session.systemHeard)
                        .frame(width: 130)
                }
            }
            if isWarming {
                Label("Connecting…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if showPicker { meetingTypeRow }
            stopButton
        }
    }

    private var timerView: some View {
        Text(timerText)
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
    }

    /// Meeting-type picker, settable mid-recording so the end-of-meeting notes
    /// pass is biased toward the right shape. Bound straight to the live
    /// session's meta; persisted when recording stops.
    private var meetingTypeRow: some View {
        HStack(spacing: 6) {
            Text("Notes style")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Notes style", selection: $session.meta.meetingType) {
                ForEach(MeetingTypeRegistry.all(settings: state.settings)) { def in
                    Text(def.displayName).tag(def.meetingTypeID)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            onStop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(isWarming)
        // Respond on the FIRST click even when the Meetings window is inactive,
        // instead of the click just focusing the window and needing a second.
        .overlay(FirstMouseCatcher(isEnabled: !isWarming, action: onStop))
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

private enum MeetingColumnMetrics {
    /// Fixed header zone so every column's content surface starts at the same Y.
    static let headerHeight: CGFloat = 40
}

/// The main columns — Pad, Live notes, Coach, and (when shown) Evidence (shared
/// screen + transcript). A plain SwiftUI `HStack`. This is robust now that the
/// live recording is hosted **full-window** (outside the `NavigationSplitView`
/// detail) — the safe-area-propagation bug that broke the hand-built fill-column
/// layout (rdar://122947424) lives specifically in `NavigationSplitView`'s
/// detail column, so a plain HStack outside it lays out reliably.
private struct MeetingLiveColumns: View {
    @Bindable var session: MeetingSession
    /// Whether the Evidence column (shared screen + transcript) is shown.
    let showEvidence: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PadColumn(session: session)
            LiveNotesColumn(session: session)
            CoachColumn(session: session)
            if showEvidence {
                EvidenceColumn(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One column: a fixed-height header zone (so every column's surface starts at
/// the same Y) over its content. Shared shape across all four live columns.
private struct ColumnFrame<Trailing: View, Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(tint)
                Text(title).font(.headline)
                Spacer()
                trailing()
            }
            .frame(height: MeetingColumnMetrics.headerHeight, alignment: .topLeading)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct PadColumn: View {
    @Bindable var session: MeetingSession
    var body: some View {
        ColumnFrame(title: "Pad", systemImage: "pencil.line") {
            if !session.padText.isEmpty {
                CopyButton(text: session.padText, label: "Copy")
            }
        } content: {
            MeetingPadEditor(session: session)
        }
    }
}

private struct LiveNotesColumn: View {
    @Environment(AppState.self) private var state
    @Bindable var session: MeetingSession

    var body: some View {
        // The live-notes status line slots under the title inside the fixed-height
        // header, so the surface still lines up with the other columns.
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text("Live notes").font(.headline)
                    Spacer()
                    if let notes = session.notesAccumulator?.liveNotes, !notes.isEmpty {
                        CopyButton(text: notes, label: "Copy")
                    }
                }
                if let acc = session.notesAccumulator {
                    NotesStatusLine(accumulator: acc)
                }
            }
            .frame(height: MeetingColumnMetrics.headerHeight, alignment: .topLeading)

            if let acc = session.notesAccumulator {
                LiveNotesField(accumulator: acc)
            } else {
                Text(notesDisabledMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var notesDisabledMessage: String {
        if state.settings.activeLLMEngine() == nil {
            return "Turn on an LLM in Settings → Models to see notes build live as the meeting happens."
        }
        if !state.settings.meetingLiveTranscriptEnabled {
            return "Live transcript is off. Turn on “Show a live transcript while recording” in Meetings settings to watch notes build here."
        }
        return "Live notes are off. Turn on “Build a first pass while recording” in Meetings settings to watch them build here."
    }
}

private struct CoachColumn: View {
    @Bindable var session: MeetingSession

    var body: some View {
        ColumnFrame(title: "Coach", systemImage: "checklist") {
            if session.coachEngine?.chipHidden == true {
                Button { session.coachEngine?.chipHidden = false } label: {
                    Label("Show on island", systemImage: "arrow.up.forward.square")
                        .font(.caption2)
                }
                .buttonStyle(.link)
                .help("Bring the coach strip back to the top of the screen")
            }
        } content: {
            if let coach = session.coachEngine {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        CoachMetricsStrip(engine: coach)
                        subsection("Key points") { CoachChecklistPanel(engine: coach) }
                        Divider()
                        subsection("Opportunities") { CoachOpportunitiesPanel(engine: coach) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .notesSurface()
                    .padding(.bottom, 2)
                }
            } else {
                Text("Coach is off for this meeting.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func subsection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
    }
}

private struct EvidenceColumn: View {
    @Bindable var session: MeetingSession

    var body: some View {
        ColumnFrame(title: "Shared screen", systemImage: "rectangle.on.rectangle.angled") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                LiveScreenCapturePanel(session: session, compact: true)
                if let transcriber = session.liveTranscriber {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live transcript")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        LiveTranscriptPane(transcriber: transcriber)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Transparent overlay that makes its host respond to the *first* click even
/// when the window is inactive — fixing the "click Stop, the app just focuses,
/// click again" two-step. When enabled it intercepts the click and forwards it
/// to `action`; when disabled it's hit-transparent so the view beneath behaves
/// normally.
private struct FirstMouseCatcher: NSViewRepresentable {
    var isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onClick = action
        v.isEnabledCatch = isEnabled
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CatcherView else { return }
        v.onClick = action
        v.isEnabledCatch = isEnabled
    }

    final class CatcherView: NSView {
        var onClick: (() -> Void)?
        var isEnabledCatch = true

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            isEnabledCatch ? super.hitTest(point) : nil
        }

        override func mouseDown(with event: NSEvent) {
            // Claim the mouse session so we also receive the matching mouseUp.
        }

        override func mouseUp(with event: NSEvent) {
            guard isEnabledCatch else { return }
            let p = convert(event.locationInWindow, from: nil)
            if bounds.contains(p) { onClick?() }
        }
    }
}

private struct LabeledWaveform: View {
    let label: String
    let level: Float
    let tint: Color
    /// Once this side has delivered real audio, show an affirmative check —
    /// positive proof the source is being captured.
    var heard: Bool = false
    /// Soft hint shown under the meter when this side has stayed silent while
    /// the other is active (e.g. call audio not routed through this Mac).
    var waitingHint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if heard {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Audio is being captured from this source.")
                }
                Spacer()
            }
            Waveform(level: level, tint: tint, honest: true)
            if let waitingHint {
                Text(waitingHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.3), value: heard)
    }
}

private enum StepStatus { case done, active, pending }

private struct ProcessingPane: View {
    @Bindable var session: MeetingSession

    // Processing now finishes at the transcript — notes are a separate,
    // user-triggered step (the Generate button), so they aren't listed here.
    private static let steps: [(title: String, symbol: String)] = [
        ("Transcribing what was said", "waveform"),
        ("Identifying who spoke", "person.2.wave.2"),
        ("Writing the transcript", "doc.text"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.headline)
                ProgressView(value: overall)
                    .progressViewStyle(.linear)
                    .accessibilityValue("\(Int(overall * 100)) percent")
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { idx, step in
                    StepRow(title: step.title, status: status(for: idx))
                }
            }

            // Keep the rough live notes visible while the full pass computes —
            // never go fully blank, and the handoff to the final notes reads
            // as a refinement of what the user already watched.
            if let notes = session.meta.notes, !notes.markdown.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes so far")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        MarkdownNotesView(markdown: notes.markdown, speakers: session.meta.speakers)
                            .padding(14)
                    }
                    .frame(maxHeight: 280)
                    .notesSurface()
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var headline: String {
        if case .importing(let p) = session.state { return "Importing audio · \(Int(p * 100))%" }
        return "Processing your meeting…"
    }

    private var activeIndex: Int {
        switch session.state {
        case .importing, .loadingASR, .transcribingMic, .transcribingSystem: return 0
        case .loadingDiarizer, .diarizing: return 1
        case .merging: return 2
        default: return 0
        }
    }

    private var fraction: Double {
        switch session.state {
        case .importing(let p), .loadingASR(let p), .transcribingMic(let p),
             .transcribingSystem(let p), .loadingDiarizer(let p), .diarizing(let p):
            return p
        case .merging: return 0.6
        default: return 0
        }
    }

    /// One monotonic 0…1 across all steps, so the bar climbs steadily instead
    /// of snapping back to zero at every stage boundary.
    private var overall: Double {
        (Double(activeIndex) + min(1, max(0, fraction))) / Double(Self.steps.count)
    }

    private func status(for idx: Int) -> StepStatus {
        if idx < activeIndex { return .done }
        if idx == activeIndex { return .active }
        return .pending
    }
}

private struct StepRow: View {
    let title: String
    let status: StepStatus

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch status {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active:
                    ProgressView().controlSize(.small)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.callout)
                .fontWeight(status == .active ? .semibold : .regular)
                .foregroundStyle(status == .pending ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer()
        }
        .accessibilityElement(children: .combine)
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

/// Live shared-screen capture card: what window is being grabbed, a thumbnail
/// of the most recent kept frame, and a "Change" menu to retarget. Reads the
/// observable `MeetingScreenCapturer` so the target + latest frame update live.
/// Handles its own empty / no-window / permission states so the parent only has
/// to decide whether the feature is on.
private struct LiveScreenCapturePanel: View {
    @Bindable var session: MeetingSession
    /// In the evidence column the preview is capped so the transcript beneath it
    /// keeps room; full size is always a click away via Quick Look.
    var compact = false

    @State private var targets: [MeetingScreenCapturer.CaptureTarget] = []
    @State private var latestImage: NSImage?
    @State private var hasPermission = true
    @State private var busy = false
    @State private var quickLookURL: URL?

    private var capturer: MeetingScreenCapturer { session.screenCapturer }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                Text("Shared screen")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                if hasPermission { changeMenu }
            }

            if !hasPermission {
                permissionNotice
            } else {
                controls
                targetLine
                preview
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Content panel → solid surface, matching the Pad / Live-notes / Coach
        // columns. Glass here produced the stray drop shadow against the column.
        .notesSurface()
        .quickLookPreview($quickLookURL)
        .task(id: capturer.latestScreenshotURL) {
            guard let url = capturer.latestScreenshotURL else { latestImage = nil; return }
            latestImage = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
        .task(id: capturer.isCapturing) { await refreshTargets() }
        .task { await refreshTargets() }
    }

    // The per-meeting on/off + a force-capture. The toggle genuinely starts /
    // stops the stream, so the system capture indicator tracks reality.
    private var controls: some View {
        HStack(spacing: 10) {
            Toggle("Capture", isOn: Binding(
                get: { capturer.isCapturing },
                set: { on in
                    Task {
                        busy = true
                        if on { await capturer.enable() } else { await capturer.disable() }
                        await refreshTargets()
                        busy = false
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(busy)

            Spacer()

            Button {
                Task { busy = true; await capturer.captureNow(); await refreshTargets(); busy = false }
            } label: {
                Label("Capture now", systemImage: "camera")
                    .font(.caption2)
            }
            .controlSize(.small)
            .disabled(busy)
            .help("Grab a screenshot of the meeting window right now")
        }
    }

    private var changeMenu: some View {
        Menu {
            if targets.isEmpty {
                Text("No meeting windows found")
            }
            ForEach(targets) { target in
                Button {
                    Task { busy = true; await capturer.switchTo(windowID: target.windowID); await refreshTargets(); busy = false }
                } label: {
                    if target.id == capturer.currentTarget?.id {
                        Label(target.label, systemImage: "checkmark")
                    } else {
                        Text(target.label)
                    }
                }
            }
            Divider()
            Button("Refresh list") { Task { await refreshTargets() } }
        } label: {
            Label("Change", systemImage: "macwindow.on.rectangle")
                .font(.caption2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which meeting window to capture")
    }

    // Always one line (same height whether capturing or off) so toggling Capture
    // doesn't change the panel's height and reflow the inspector.
    @ViewBuilder
    private var targetLine: some View {
        Group {
            if capturer.isCapturing, let target = capturer.currentTarget {
                Text("Capturing \(target.label)")
            } else {
                Text("Capture is off — turn it on, or hit Capture now.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Fixed height regardless of state (image ⇄ placeholder), so toggling Capture
    // never changes the panel's height — a height change here reflows the whole
    // inspector and re-trips the content-under-the-toolbar bug. Click → Quick Look.
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.25))
            if let latestImage {
                Image(nsImage: latestImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed")
                        .imageScale(.large)
                        .foregroundStyle(.tertiary)
                    Text(capturer.isCapturing ? "Waiting for shared content…" : "Nothing captured yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 180 : 240)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture {
            if capturer.latestScreenshotURL != nil { quickLookURL = capturer.latestScreenshotURL }
        }
        .help(latestImage != nil ? "Click to open full size" : "")
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen Recording permission is needed to capture shared screens.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                ScreenRecordingPermission.openSystemSettings()
            }
            .font(.caption2)
            .buttonStyle(.link)
        }
    }

    private func refreshTargets() async {
        hasPermission = ScreenRecordingPermission.hasAccess()
        targets = await capturer.availableTargets()
    }
}

/// Live-recording draft transcript. Fills in chunk by chunk while the meeting
/// records; the canonical, diarized transcript replaces it as soon as the
/// post-capture processor finishes. No speaker attribution in this view —
/// that's the post-pass's job. Empty state shows a "Listening…" placeholder
/// so the user can see the pane wired up even before the first chunk lands.
/// One-line status under the live "Notes" header: a calm "Updating…" pulse
/// while a pass runs, otherwise a stat that visibly climbs ("3 topics · 8
/// points · updated 12s ago"). The relative time re-renders each second via a
/// TimelineView so the cadence is always legible between passes.
private struct NotesStatusLine: View {
    @Bindable var accumulator: MeetingNotesAccumulator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                if accumulator.isThinking {
                    PulsingDot()
                    Text("Updating notes…")
                } else {
                    Text(statText(now: context.date))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(height: 14)
    }

    private func statText(now: Date) -> String {
        let topics = accumulator.topicCount
        let points = accumulator.pointCount
        guard points > 0 else { return "Listening for the first points…" }
        var parts: [String] = []
        if topics > 0 { parts.append("\(topics) topic\(topics == 1 ? "" : "s")") }
        parts.append("\(points) point\(points == 1 ? "" : "s")")
        if let last = accumulator.lastUpdateAt {
            parts.append("updated \(Self.relative(now.timeIntervalSince(last)))")
        }
        return parts.joined(separator: " · ")
    }

    private static func relative(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 3 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        return "\(s / 60)m ago"
    }
}

/// A slow-pulsing dot — a calmer "working" affordance than a spinner.
private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.purple)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// The user's own pad for a meeting — an editable markdown text area backed
/// by `session.padText` (debounced autosave to `pad.md`, flushed when the
/// view goes away). Shared between the live-recording left column and the
/// post-meeting Pad tab; the final notes pass folds the pad in as
/// authoritative input.
struct MeetingPadEditor: View {
    @Bindable var session: MeetingSession
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: Binding(
            get: { session.padText },
            set: { session.updatePad($0) }
        ))
        .font(.system(.callout, design: .monospaced))
        .focused($focused)
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notesSurface()
        .overlay(alignment: .topLeading) {
            // Hidden on focus — the caret sits at the editor's own text
            // inset, which never quite matched the overlay's, so a blinking
            // caret misaligned with ghost text read as a glitch.
            if session.padText.isEmpty && !focused {
                Text(placeholder)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .onDisappear { session.flushPad() }
    }

    private var placeholder: String {
        var text = "Jot your own notes here — names, decisions, things to chase. They're folded into the final notes as ground truth."
        if session.coachEngine != nil {
            text += " Start a line with ! to add it to the coach's key points."
        }
        return text
    }
}

/// The live first-pass notes shown during recording. Streams the structured
/// outline — new bullets animate in under their topic and briefly highlight —
/// rather than re-rendering the whole document each pass. Auto-scrolls to the
/// bottom only when the reader is already there; otherwise a "New notes" pill
/// appears. Read-only but selectable, so it's easy to copy straight out.
private struct LiveNotesField: View {
    @Bindable var accumulator: MeetingNotesAccumulator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinnedToBottom = true
    @State private var showJumpPill = false
    private static let bottomAnchor = "live-notes-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    Group {
                        if accumulator.outline.isEmpty {
                            Text("Notes will appear here as the meeting gets going…")
                                .italic()
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LiveOutlineView(
                                outline: accumulator.outline,
                                freshIDs: accumulator.freshBulletIDs,
                                reduceMotion: reduceMotion
                            )
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 28
                } action: { _, nearBottom in
                    pinnedToBottom = nearBottom
                    if nearBottom { showJumpPill = false }
                }
                .onChange(of: accumulator.outline) { _, _ in
                    if pinnedToBottom {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    } else {
                        showJumpPill = true
                    }
                }

                if showJumpPill {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                        showJumpPill = false
                    } label: {
                        Label("New notes", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .meetingGlassControl(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .notesSurface()
    }
}

/// Renders the accumulator's structured outline with per-bullet identity, so
/// SwiftUI keeps unchanged rows in place and only animates genuinely new ones
/// (and washes them with a brief highlight). Motion is gated on reduce-motion.
private struct LiveOutlineView: View {
    let outline: [MeetingNotesAccumulator.NoteGroup]
    let freshIDs: Set<String>
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(outline) { group in
                VStack(alignment: .leading, spacing: 6) {
                    if !group.heading.isEmpty {
                        inlineMarkdownText(group.heading).font(.headline)
                    } else if !group.bullets.isEmpty {
                        Text("General")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.bullets) { bullet in
                        bulletRow(bullet)
                            .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: outline)
        .animation(.easeInOut(duration: 0.8), value: freshIDs)
    }

    private func bulletRow(_ bullet: MeetingNotesAccumulator.NoteBullet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(bullet.indent > 0 ? "◦" : "•").foregroundStyle(.secondary)
            inlineMarkdownText(bullet.text).font(.callout)
        }
        .padding(.leading, CGFloat(bullet.indent) * 18)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(freshIDs.contains(bullet.id) ? Color.accentColor.opacity(0.14) : .clear)
        )
    }
}

private struct LiveTranscriptPane: View {
    @Bindable var transcriber: MeetingLiveTranscriber

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if transcriber.liveDisplayText.isEmpty {
                        Text("Listening…")
                            .italic()
                            .foregroundStyle(.tertiary)
                    } else {
                        // The trailing bottomAnchor view is what the
                        // ScrollViewReader pins to as new chunks land —
                        // gives us the auto-scroll-to-bottom behaviour
                        // without any manual scroll-offset math.
                        // TypewriterText streams each utterance in word by
                        // word the moment its provisional transcription
                        // lands, then visibly revises when the settled
                        // version replaces it; per-word ticks keep the
                        // scroll pinned.
                        TypewriterText(
                            target: transcriber.liveDisplayText,
                            idleIndicator: transcriber.isRunning ? .blinkingCursor : .none,
                            onTick: { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                        )
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
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
