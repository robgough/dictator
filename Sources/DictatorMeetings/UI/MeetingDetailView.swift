import SwiftUI
import AppKit
import QuickLook

/// Renders one meeting. The three modes (live recording, processing,
/// ready) all share a header and switch the body underneath.
struct MeetingDetailView: View {
    @Environment(MeetingsAppState.self) private var state
    @Bindable var session: MeetingSession
    @State private var titleDraft: String = ""
    /// The meeting the title field is drafting a rename for, captured the
    /// moment editing begins and held until that edit commits or is
    /// abandoned. This view is REUSED when the user picks another meeting
    /// (see the `session.id` onChange below), so `session` can be swapped
    /// out from under a half-typed title; renaming whatever `session` points
    /// at when the commit lands is how a rename ended up on a different
    /// meeting. The captured target is immutable for the life of the edit,
    /// so the commit always reaches the meeting the user was typing into.
    @State private var titleTarget: MeetingSession?
    @FocusState private var titleFocused: Bool
    @State private var transcriptCache: MeetingTranscript?
    /// Matches the transcript load in flight; a load for a meeting the user
    /// has already left is dropped when it lands.
    @State private var transcriptLoadToken = UUID()
    @State private var titleHovered = false
    /// Whether the trailing Details inspector is showing. Remembered across
    /// launches; only takes effect for finished meetings (see `canShowInspector`).
    @AppStorage("meetingsInspectorVisible") private var inspectorVisible = true
    /// Which of the side panel's two faces shows: "details" or "ask".
    @AppStorage("meetingsInspectorTab") private var inspectorTab = "details"
    /// The conversation about this meeting. Owned here, not by the notes,
    /// because three things reach it: the Assistant button on the notes,
    /// ⌘⌥A, and the Ask panel itself.
    @State private var assistant = MeetingAssistantController()

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
        // Don't stomp what the user is typing: an auto-rename (or any other
        // background meta write) landing mid-edit would otherwise replace the
        // draft under the caret.
        .onChange(of: session.meta.title) { _, new in
            guard !titleFocused else { return }
            titleDraft = new
        }
        .onChange(of: session.state) { _, _ in reloadTranscriptIfNeeded() }
        // When the user picks a different meeting in the sidebar SwiftUI
        // reuses this view instance and just swaps the bound session.
        // `@State` (titleDraft / transcriptCache) survives the swap, so
        // without this onChange both stay stuck on the previous meeting's
        // values — the title happens to update via its own onChange, but
        // the transcript would silently keep showing the old one.
        .onChange(of: session.id) { _, _ in
            // Flush a half-typed title to the meeting it was typed into
            // BEFORE the draft is reset — the swap can arrive before the
            // field has resigned focus and committed.
            commitTitleEdit()
            titleFocused = false
            titleDraft = session.meta.title
            transcriptCache = nil
            reloadTranscriptIfNeeded()
        }
        // A speaker merge rewrites transcript.json in place without a state
        // transition — refresh the cache so the new attribution shows.
        .onChange(of: session.transcriptRevision) { _, _ in
            loadTranscript()
        }
        // Trailing Details inspector — metadata, speaker editing, and the
        // on-demand notes control. Only for finished meetings, so it never
        // squeezes the fixed-width live-recording layout.
        .inspector(isPresented: inspectorBinding) {
            MeetingSidePanel(session: session, assistant: assistant, tab: $inspectorTab)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .onAppear {
            assistant.bind(session: session)
            state.meetingAssistant = assistant
        }
        .onChange(of: session.id) { _, _ in
            assistant.bind(session: session)
            state.meetingAssistant = assistant
        }
        .onChange(of: assistant.openRequests) { _, _ in
            inspectorTab = "ask"
            inspectorVisible = true
        }
        .onDisappear {
            assistant.teardown()
            if state.meetingAssistant === assistant { state.meetingAssistant = nil }
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
    /// actually being a finished one. Writing through it persists the toggle.
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
                TextField("Title", text: $titleDraft)
                .focused($titleFocused)
                // Return commits, and so does clicking away (Finder/Notes
                // behaviour) — both through `commitTitleEdit`, which renames
                // the captured target rather than the currently-bound session.
                .onSubmit {
                    // Return is only reachable while the field has focus, so
                    // if focus tracking somehow never fired, the bound session
                    // is the right target — better than dropping the rename.
                    if titleTarget == nil { titleTarget = session }
                    commitTitleEdit()
                }
                .onChange(of: titleFocused) { _, focused in
                    if focused {
                        titleTarget = session
                    } else {
                        commitTitleEdit()
                        // Whatever the field editor pushed back on its way
                        // out (it can carry the previous meeting's text when
                        // the selection changed mid-edit), the header must
                        // show the persisted title of the meeting on screen.
                        titleDraft = session.meta.title
                    }
                }
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

    /// Commit the in-progress title edit to `titleTarget` — the meeting that
    /// was bound when the user started typing, not whatever `session` points
    /// at now. Clearing the target first makes this idempotent: focus loss,
    /// Return, and a session swap can all fire for the same edit, and only
    /// the first one writes. Empty titles are rejected (and the field is put
    /// back to the real title so it doesn't sit blank).
    private func commitTitleEdit() {
        guard let target = titleTarget else { return }
        titleTarget = nil
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if target === session { titleDraft = session.meta.title }
            return
        }
        guard trimmed != target.meta.title else { return }
        target.rename(to: trimmed)
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
            case .recording:
                // The live view's status strip already shows the time, big;
                // a pill repeating it beside the title was the third copy.
                EmptyView()
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

    /// Decode transcript.json off the main thread. A long meeting's runs to
    /// over a megabyte of word timings, and decoding it inline held up the
    /// click that selected the meeting.
    private func loadTranscript() {
        let id = session.id
        let token = UUID()
        transcriptLoadToken = token
        Task.detached(priority: .userInitiated) {
            let transcript = MeetingStorage.readTranscript(for: id)
            await MainActor.run {
                guard transcriptLoadToken == token else { return }
                transcriptCache = transcript
            }
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
            loadTranscript()
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

/// Live-recording body. A status strip across the top — the time, whether
/// each side is being heard, the coach's numbers, the notes style and Stop —
/// over two columns: the notes the meeting is producing on the left (the star
/// of the show), and one full-height side panel on the right that shows key
/// points, the live transcript or the shared screen, one at a time.
///
/// The side panel used to stack all of those as cards in a 300pt scrolling
/// column, with the transcript pinned at 220pt. Everything got a sliver: the
/// transcript cut off mid-line, an idle screen-capture box took 200pt, and the
/// elapsed time appeared three times. One thing at a time, at full height, is
/// what each of them actually needs.
struct LiveRecordingView: View {
    @Environment(MeetingsAppState.self) private var state
    @Bindable var session: MeetingSession
    let isWarming: Bool

    enum SideTab: String, CaseIterable, Identifiable {
        case keyPoints, transcript, screen
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keyPoints: return "Key points"
            case .transcript: return "Transcript"
            case .screen: return "Screen"
            }
        }
    }

    /// Remembered, because someone who watches the transcript watches it every
    /// meeting. `AppDefaults` so a screenshot run can't touch the real value.
    @AppStorage("meetingsLiveSideTab", store: AppDefaults.shared)
    private var storedSideTab: SideTab = .transcript

    var body: some View {
        VStack(spacing: 14) {
            statusStrip
            HStack(alignment: .top, spacing: 16) {
                notesColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                sidePanel
                    .frame(width: 320)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Status strip (top)

    private var statusStrip: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(isWarming ? Color.orange : Color.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !isWarming)
                timerView
            }
            stripDivider
            HStack(spacing: 18) {
                SourceMeter(label: "You", level: levels.mic, tint: .accentColor, heard: session.micHeard)
                SourceMeter(
                    label: "Other side",
                    level: levels.system,
                    tint: .indigo,
                    heard: session.systemHeard,
                    waitingHint: systemWaitingHint
                )
            }
            if isWarming {
                stripDivider
                Label("Connecting microphone and call audio…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let coach = session.coachEngine {
                stripDivider
                // First to give way when the window is narrow.
                CoachMetricsStrip(engine: coach)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 8)
            if state.companionDismissed, state.settings.meetingCompanionEnabled {
                Button {
                    state.companionDismissed = false
                } label: {
                    Label("Companion", systemImage: "rectangle.inset.topright.filled")
                }
                .buttonStyle(.borderless)
                .help("Bring back the floating companion")
            }
            meetingTypeRow
            stopButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .meetingGlassControl(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var stripDivider: some View {
        Divider().frame(height: 32)
    }

    // MARK: - Side panel (right)

    /// The tabs this meeting can show: key points need the coach, the
    /// transcript needs live transcription; the screen is always there because
    /// it's where capture is switched on.
    private var availableTabs: [SideTab] {
        SideTab.allCases.filter { tab in
            switch tab {
            case .keyPoints: return session.coachEngine != nil
            case .transcript: return session.liveTranscriber != nil
            case .screen: return true
            }
        }
    }

    private var sideTab: Binding<SideTab> {
        Binding(
            get: {
                let tabs = availableTabs
                return tabs.contains(storedSideTab) ? storedSideTab : (tabs.first ?? .screen)
            },
            set: { storedSideTab = $0 }
        )
    }

    private var sidePanel: some View {
        VStack(spacing: 10) {
            Picker("Show", selection: sideTab) {
                ForEach(availableTabs) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch sideTab.wrappedValue {
                case .keyPoints:
                    keyPointsPane
                case .transcript:
                    if let transcriber = session.liveTranscriber {
                        LiveTranscriptPane(transcriber: transcriber)
                    }
                case .screen:
                    ScrollView {
                        LiveScreenCapturePanel(session: session)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // Live coach checklist — the key points for this meeting, ticking off as
    // the watcher catches them. Coach data is never exported with the notes.
    @ViewBuilder
    private var keyPointsPane: some View {
        if let coach = session.coachEngine {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    CoachChecklistPanel(engine: coach)
                    if coach.chipHidden {
                        Button {
                            coach.chipHidden = false
                        } label: {
                            Label("Show on island", systemImage: "arrow.up.forward.square")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .help("Bring the coach strip back to the top of the screen")
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .notesSurface()
        }
    }

    // MARK: - Notes column (left, emphasised)

    /// Pad over live notes: the user's own editable pad on top, the LLM's
    /// streaming first pass below, split by a draggable divider so both stay
    /// visible while typing. When live notes are off the pad takes the whole
    /// column and a one-line caption explains why nothing streams below.
    @ViewBuilder
    private var notesColumn: some View {
        if session.notesAccumulator != nil {
            VSplitView {
                padPane
                    .frame(minHeight: 110)
                    .padding(.bottom, 8)
                liveNotesPane
                    .frame(minHeight: 130)
                    .padding(.top, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                padPane
                Text(notesDisabledMessage)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var padPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(.secondary)
                Text("Pad")
                    .font(.headline)
                Spacer()
                if !session.padText.isEmpty {
                    CopyButton(text: session.padText, label: "Copy")
                }
            }
            MeetingPadEditor(session: session)
        }
    }

    private var liveNotesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Live notes")
                    .font(.headline)
                Spacer()
                if let notes = session.notesAccumulator?.liveNotes, !notes.isEmpty {
                    CopyButton(text: notes, label: "Copy")
                }
            }
            if let acc = session.notesAccumulator {
                NotesStatusLine(accumulator: acc)
                LiveNotesField(accumulator: acc)
            }
        }
    }

    private var notesDisabledMessage: String {
        if ProviderRegistry.shared.provider(for: .live) == nil {
            return "Pick a model for live notes on the Providers tab to see notes build as the meeting happens."
        }
        if !state.settings.meetingLiveTranscriptEnabled {
            return "Live transcript is off. Turn on “Show a live transcript while recording” in Meetings settings to watch notes build here."
        }
        return "Live notes are off. Turn on “Build a first pass while recording” in Meetings settings to watch them build here."
    }

    /// Soft hint when the remote side has stayed silent a while into the call
    /// despite the mic being live — usually means call audio isn't routed
    /// through this Mac for the system tap to capture.
    private var systemWaitingHint: String? {
        guard case .recording(let elapsed, _, _) = session.state else { return nil }
        guard !session.systemHeard, session.micHeard, elapsed > 6 else { return nil }
        return "No call audio yet"
    }

    /// Meeting-type picker as a compact chip, settable mid-recording so the
    /// end-of-meeting notes pass is biased toward the right shape (stand-up,
    /// retro, 1-on-1, …). Bound straight to the live session's meta; persisted
    /// when recording stops along with the rest of the meta.
    private var meetingTypeRow: some View {
        // A menu labelled with the current choice rather than a picker: a menu
        // picker sizes itself to its longest option, which made this the
        // widest thing in the strip.
        Menu {
            Picker("Notes style", selection: $session.meta.meetingType) {
                ForEach(MeetingTypeRegistry.all(settings: state.settings)) { def in
                    Text(def.displayName).tag(def.meetingTypeID)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                "Notes: " + MeetingTypeRegistry.displayName(for: session.meta.meetingType, settings: state.settings),
                systemImage: "doc.text")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The shape the final notes will take. Settable now so it's already right when the call ends.")
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            performStop()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .padding(.horizontal, 6)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(isWarming)
        // Respond on the FIRST click even when the Meetings window is inactive,
        // instead of the click just focusing the window and needing a second.
        .overlay(FirstMouseCatcher(isEnabled: !isWarming, action: performStop))
    }

    private func performStop() {
        Task {
            await session.stopRecording(parakeetModelID: state.settings.parakeetModelID)
        }
    }

    private var timerView: some View {
        Text(timerText)
            .font(.system(.title2, design: .rounded).weight(.semibold))
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

/// One side of the call: its name, a live meter, and whether it's being heard.
///
/// The meter is the app-wide `Waveform` — the one the dictation HUD, the chat
/// composer and the journal recorder show — in its honest mode, so it sits flat
/// on real silence and moves in proportion to real input: here it is the proof
/// each side is being captured. It stays grey until this side has actually
/// delivered audio and takes its colour once it has, with a check beside the
/// name; the words "Hearing audio" live in the tooltip rather than repeating
/// under both meters. A problem is the one thing spelled out.
struct SourceMeter: View {
    let label: String
    let level: Float
    let tint: Color
    /// Once this side has delivered real audio.
    var heard: Bool = false
    /// Set when this side is expected but has stayed silent (e.g. call audio
    /// not routed through this Mac).
    var waitingHint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
                Text(waitingHint ?? label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(waitingHint != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .fixedSize()
            }
            Waveform(
                level: level,
                tint: heard ? tint : Color.secondary.opacity(0.45),
                honest: true,
                barCount: 22,
                height: 20
            )
            .frame(width: 118)
        }
        .animation(.easeOut(duration: 0.3), value: heard)
        .help(heard
              ? "\(label): hearing audio."
              : (waitingHint ?? "\(label): waiting for audio…"))
    }

    private var iconName: String {
        if heard { return "checkmark.circle.fill" }
        if waitingHint != nil { return "exclamationmark.triangle.fill" }
        return "circle.dotted"
    }

    private var iconColor: Color {
        if heard { return .green }
        if waitingHint != nil { return .orange }
        return .secondary
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
                    Text("Live notes")
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

    @State private var targets: [MeetingScreenCapturer.CaptureTarget] = []
    @State private var latestImage: NSImage?
    @State private var hasPermission = true
    @State private var busy = false
    @State private var quickLookURL: URL?

    private var capturer: MeetingScreenCapturer { session.screenCapturer }

    var body: some View {
        // Lives on its own tab of the side panel, which names it, so no title
        // row — and the same quiet surface as the transcript beside it rather
        // than a glass card of its own.
        VStack(alignment: .leading, spacing: 10) {
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

            changeMenu
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

    @ViewBuilder
    private var targetLine: some View {
        if capturer.isCapturing, let target = capturer.currentTarget {
            Text("Capturing \(target.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("Capture is off. Turn it on for a stretch, or hit Capture now for a one-off — frames stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Stretches the most recent frame to the full card width (height follows the
    // image's aspect) so it's as large as the column allows; click → Quick Look.
    private var preview: some View {
        // The frame caps live on the content (not an unbounded ZStack rectangle),
        // and the fill is a `.background`, so the preview hugs its content and is
        // safe inside the scrolling controls column (a greedy fill would expand
        // to infinite height there).
        Group {
            if let latestImage {
                Image(nsImage: latestImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 420)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "rectangle.dashed")
                        .imageScale(.large)
                        .foregroundStyle(.tertiary)
                    Text(capturer.isCapturing ? "Waiting for shared content…" : "Nothing captured yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
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
            // The same surface as the pad and live notes beside it, so the
            // three panes read as one set.
            .notesSurface()
            .onChange(of: transcriber.interimText) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomAnchor = "live-transcript-bottom"
}
