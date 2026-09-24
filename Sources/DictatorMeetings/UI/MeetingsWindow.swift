import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Reference-type cache backing `MeetingsRootView.session(for:)`. See
/// the `sessionCache` declaration for the rationale — in short, it's
/// filled lazily during `body`, and mutating a class is invisible to
/// SwiftUI's update tracking, so it sidesteps the "Modifying state
/// during view update" warning a `@State` dictionary would raise.
/// Main-actor-isolated to match `MeetingSession`; only ever touched
/// from the view's main-actor methods.
@MainActor
private final class SessionCache {
    var byID: [UUID: MeetingSession] = [:]
}

/// Root view of the Meetings window: a library, shaped like Mail and Notes.
/// The sidebar picks Today or a list (all meetings, the ones needing notes, a
/// kind of meeting, a person); a list puts a meeting column beside the
/// meeting itself. A recording on screen takes the full width, because the
/// live layout needs it — choosing a list brings the column back, and the
/// recording stays one click away at the top of it.
struct MeetingsRootView: View {
    @Environment(MeetingsAppState.self) private var state
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var store = MeetingsStore.shared
    /// Session-only demo mode. Observed here for the sidebar pill and so the
    /// list re-renders the moment it's switched on or off.
    @State private var demo = MeetingsDemoMode.shared
    @State private var selectedID: UUID?
    /// What the sidebar has selected. Optional because a sidebar `List` needs
    /// a way to show nothing selected — which is what it shows while the
    /// recording has the window, so that choosing any list, Today included,
    /// registers as a change and takes you back to it.
    @State private var scope: LibraryScope? = .today
    @State private var liveSession: MeetingSession?
    @State private var searchText = ""
    /// One session per opened meeting, memoised so the detail pane
    /// doesn't rebuild its @Observable owner on every redraw and a
    /// session keeps its in-flight state across selection changes.
    ///
    /// Deliberately a reference type rather than a `@State` dictionary:
    /// `session(for:)` fills it lazily from inside `detail`, i.e.
    /// *during* `body` evaluation, and writing through a `@State`
    /// collection there trips SwiftUI's "Modifying state during view
    /// update" runtime warning. Mutating a plain class is invisible to
    /// SwiftUI's update tracking — which is fine here, because nothing
    /// renders off this cache directly (the detail pane keys off
    /// `liveSession` / `selectedID`), so the fill doesn't need to drive
    /// an invalidation.
    @State private var sessionCache = SessionCache()
    @State private var showingPermissionBanner = false
    @State private var permissionMessage: String?
    /// Raised when the user tries to record/import but the Parakeet speech
    /// model isn't on disk. Meetings always transcribe with Parakeet (on the
    /// ANE, so live notes don't fight the summary LLM for the GPU), so it's a
    /// hard requirement — we'd rather prompt to download it up front than kick
    /// off a multi-hundred-MB download in the middle of a live recording.
    @State private var showingParakeetGate = false

    /// Raised when the user tries to record/import with no usable LLM to
    /// write notes (no engine selected, Apple Intelligence unavailable, or
    /// the chosen MLX model not downloaded — see
    /// `ProviderRegistry.shared.requirementMessage`). Blocking up front beats
    /// recording an hour of audio we then can't turn into notes. A merely
    /// *non-recommended* model doesn't block — it's the user's call.
    @State private var showingMeetingLLMGate = false
    /// The specific reason captured when `showingMeetingLLMGate` fires, so
    /// the alert can explain exactly what's missing.
    @State private var meetingLLMGateMessage = ""

    /// True while a file is dragged over the window — drives the glass drop
    /// overlay that replaced the always-visible dashed sidebar drop-zone.
    @State private var isDropTargeted = false

    /// Whether the Details inspector is showing. Shares the key with
    /// `MeetingDetailView`'s `.inspector` binding, so the toolbar toggle here
    /// and the pane there stay in lockstep. Lives in the window toolbar (with a
    /// flexible spacer before it) so the toggle sits above the inspector while
    /// the capture + document controls stay above the main content.
    @AppStorage("meetingsInspectorVisible") private var inspectorVisible = true

    /// Whether the Parakeet model meetings depend on is downloaded and ready.
    private var parakeetReady: Bool {
        ParakeetService.modelsExist(id: state.settings.parakeetModelID)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
                // Bound the sidebar so it can't be dragged wide enough to
                // squeeze the detail column below its own minimum. Unbounded,
                // a dragged-out sidebar (309pt here) plus the detail's
                // inspector (min 240) left the detail less than it could
                // compress to, and the min-size negotiation between the
                // hosting views and AppKit's split view never settled — the
                // window ran out of Update Constraints passes and the app
                // aborted. The width is persisted per window, so a sidebar
                // already dragged past `max` is clamped back on next open.
                .navigationSplitViewColumnWidth(min: 200, ideal: 280, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("Meetings")
        // Two glass clusters on macOS 26: the mic + record/stop capture
        // controls, then Import on its own. ToolbarSpacer splits them into
        // separate Liquid Glass capsules. The detail view contributes a third
        // trailing group (Share + Details) for the selected meeting.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                recordOrStopButton
                importButton
                if let session = shareableSession {
                    shareMenu(for: session)
                }
                if let session = currentSession {
                    Button { showInFinder(session) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .help("Open this meeting's folder in Finder.")
                }
            }
            // A small gap sets the inspector toggle apart from the action
            // group, so it reads as the open/close-sidebar control.
            if shareableSession != nil {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button { inspectorVisible.toggle() } label: {
                        Label("Details", systemImage: "sidebar.right")
                    }
                    .help("Show or hide meeting details.")
                }
            }
        }
        .onAppear {
            // Screenshot mode picks the meeting (or installs a fabricated live
            // session) the capture is meant to show. Inert otherwise.
            MeetingsScreenshotRunner.configure(selection: $selectedID, liveSession: $liveSession, scope: $scope)
            store.refresh()
            consumePendingRecordingRequest()
            consumePendingStopRequest()
            consumePendingShowLive()
            state.meetingsWindowIsKey = (controlActiveState == .key)
        }
        .onDisappear { state.meetingsWindowIsKey = false }
        // Track key-window state so the assistant hotkey routes to the focused
        // meeting (and the "Hold ⌘⌥A to ask" hint shows) only while this window
        // is frontmost. Re-scan the synced folder on focus too, so meetings
        // another Mac recorded show up when you switch back to this one.
        .onChange(of: controlActiveState) { _, newValue in
            let becameKey = (newValue == .key)
            state.meetingsWindowIsKey = becameKey
            if becameKey { store.refresh() }
        }
        // Catches the case where the Meetings window is *already* open
        // when the user hits "Record meeting" in the menu bar — onAppear
        // won't fire again, but the @Observable flag flip does.
        .onChange(of: state.pendingMeetingRecording) { _, isPending in
            if isPending { consumePendingRecordingRequest() }
        }
        // The companion's "Open in window", and stopping from it.
        .onChange(of: state.pendingShowLive) { _, isPending in
            if isPending { consumePendingShowLive() }
        }
        // Same for the menu bar's "Stop recording".
        .onChange(of: state.pendingStopRecording) { _, isPending in
            if isPending { consumePendingStopRequest() }
        }
        // Choosing a list while the recording has the window means "let me
        // browse": let go of the live meeting so the list can show. It keeps
        // recording, pinned at the top of the list and on Today. A meeting
        // that isn't in the new list is let go too, as Mail does.
        .onChange(of: scope) { _, newScope in
            guard let newScope else { return }
            if let live = liveSession, selectedID == live.id, live.isLive {
                selectedID = nil
            } else if let id = selectedID, newScope != .today,
                      !Library.filter(filteredMetas, by: newScope).contains(where: { $0.id == id }) {
                selectedID = nil
            }
        }
        // Demo mode switching either way changes which meetings exist, so drop
        // any selection and cached session that no longer does — otherwise a
        // fixture stays on screen after the switch goes off (the cache is keyed
        // by id and knows nothing about demo mode). A live or processing
        // session is kept: it's the user's real recording either way.
        .onChange(of: demo.isOn) { _, _ in
            sessionCache.byID = sessionCache.byID.filter { _, session in
                session.isLive || session.isProcessing
            }
            if let id = selectedID, !store.visibleMetas.contains(where: { $0.id == id }) {
                selectedID = nil
            }
        }
        .alert("Download the Parakeet speech model", isPresented: $showingParakeetGate) {
            Button("Download") {
                ModelManager.shared.downloadParakeet(
                    state.settings.parakeetModelID,
                    using: ParakeetServiceHolder.shared
                )
                state.openSettingsAction?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Meetings transcribe on-device with Parakeet, which isn’t downloaded yet. Download it (about a minute on a fast connection) and you can watch progress in Settings → Models, then start your meeting.")
        }
        .alert("Meetings need a model to write notes", isPresented: $showingMeetingLLMGate) {
            Button("Open Settings") {
                state.openSettingsAction?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(meetingLLMGateMessage)
        }
        // Whole-window drop target — drop an audio file anywhere over the
        // Meetings window to import it. A glass card surfaces only while a drag
        // is in flight, so the sidebar keeps the room the old dashed drop-zone
        // used to permanently occupy.
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedURLs(urls)
            return !urls.isEmpty
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
        .overlay {
            if isDropTargeted {
                MeetingDropOverlay()
            }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    /// Block a record/import attempt only when there's no usable LLM to
    /// write notes at all (`ProviderRegistry.shared.requirementMessage`). A
    /// non-recommended model still proceeds — the quality trade-off is the
    /// user's to make. Returns true when it's safe to proceed.
    private func ensureMeetingLLMReady() -> Bool {
        if let message = ProviderRegistry.shared.requirementMessage {
            meetingLLMGateMessage = message
            showingMeetingLLMGate = true
            return false
        }
        return true
    }

    /// Block a record/import attempt when Parakeet isn't ready, raising the
    /// download prompt instead. Returns true when it's safe to proceed.
    private func ensureParakeetReady() -> Bool {
        guard parakeetReady else {
            showingParakeetGate = true
            return false
        }
        return true
    }

    /// One-shot drain of `AppState.pendingMeetingRecording`. Set by the
    /// menu bar's "Record meeting" entry before it opens the window;
    /// cleared here so a subsequent reopen of the window doesn't
    /// re-trigger a recording.
    private func consumePendingRecordingRequest() {
        guard state.pendingMeetingRecording else { return }
        state.pendingMeetingRecording = false
        // Don't kick off a second recording if one's already live or a
        // session is mid-processing — same guard the toolbar button uses.
        if liveSession?.isLive == true || liveSession?.isProcessing == true {
            return
        }
        Task { await startRecording() }
    }

    /// One-shot drain of `MeetingsAppState.pendingStopRecording`, set by the
    /// menu-bar item. Cleared unconditionally so a stop that arrives with no
    /// live recording (the window was closed and the session went with it)
    /// can't fire later against an unrelated capture.
    private func consumePendingStopRequest() {
        guard state.pendingStopRecording else { return }
        state.pendingStopRecording = false
        guard liveSession?.isLive == true else { return }
        Task { await liveSession?.stopRecording(parakeetModelID: state.settings.parakeetModelID) }
    }

    /// Collect dropped URLs and feed them through the same import path
    /// the toolbar's Import… button uses. The drop zone uses SwiftUI's
    /// modern `.dropDestination(for: URL.self)`, which hands us real
    /// file URLs directly — far more reliable than the legacy
    /// `NSItemProvider.loadObject(ofClass: URL.self)` path, which on
    /// macOS 26 silently drops items for many providers (Voice Memos
    /// `.m4a` exports were the obvious casualty: their provider vends
    /// the file via `com.apple.m4a-audio` but not as a plain `URL`
    /// object, so `loadObject` returned nil and the import never fired).
    private func handleDroppedURLs(_ urls: [URL]) {
        // Logged so the user can verify drops are actually reaching the
        // app via Console.app — useful for any next-pass debugging.
        NSLog("[Dictator] Drop received: \(urls.count) urls — \(urls.map { $0.lastPathComponent })")
        let audioURLs = urls.filter { MeetingImporter.urlLooksLikeAudio($0) }
        guard !audioURLs.isEmpty else { return }
        Task { @MainActor in
            await importFiles(audioURLs)
        }
    }

    /// Meetings matching the search box — title, notes body, or legacy summary
    /// narrative. Transcript-text search is deferred (it'd mean loading every
    /// transcript.json); title + notes covers the common "which meeting was
    /// that" case from already-loaded metadata.
    private var filteredMetas: [MeetingMeta] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.visibleMetas }
        return store.visibleMetas.filter { m in
            m.title.lowercased().contains(q)
                || (m.notes?.markdown.lowercased().contains(q) ?? false)
                || (m.summary?.narrative.lowercased().contains(q) ?? false)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // The one place demo mode is visible as itself inside the window —
            // and the window is the thing being recorded, so it has to be here.
            // Everything below it looks exactly as it normally does.
            if demo.isOn { DemoSidebarPill() }
            LibrarySidebar(scope: $scope, metas: store.visibleMetas)
                .frame(maxHeight: .infinity)
            SyncFooterChip()
        }
    }

    /// True when the recording (or the import) in progress has the window.
    private var isShowingLive: Bool {
        guard let live = liveSession, let id = selectedID else { return false }
        return id == live.id && (live.isLive || live.isProcessing)
    }

    /// The list the meeting column shows. Today has no list of its own, so
    /// searching from Today searches everything.
    private var listScope: LibraryScope {
        guard let scope, scope != .today else { return .all }
        return scope
    }

    @ViewBuilder
    private var detail: some View {
        if (scope ?? .all) == .today && searchText.isEmpty && !isShowingLive {
            TodayView(
                metas: store.visibleMetas,
                live: liveSession,
                onRecord: { Task { await startRecording() } },
                onOpen: { id, target in
                    scope = target
                    selectedID = id
                },
                onOpenLive: openLive)
        } else {
            HStack(spacing: 0) {
                // A live recording takes the full width; see the type's doc.
                if !(isShowingLive && liveSession?.isLive == true) {
                    let metas = Library.filter(filteredMetas, by: listScope)
                    MeetingListColumn(
                        scope: listScope,
                        selection: $selectedID,
                        metas: metas,
                        live: liveSession
                    ) { id in
                        store.delete(id: id)
                        if selectedID == id { selectedID = nil }
                        sessionCache.byID.removeValue(forKey: id)
                    }
                    .frame(width: 290)
                    .overlay {
                        if metas.isEmpty && !searchText.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        }
                    }
                    Divider()
                }
                meetingPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var meetingPane: some View {
        if let id = selectedID, let live = liveSession, id == live.id {
            MeetingDetailView(session: live)
        } else if let id = selectedID, let session = session(for: id) {
            MeetingDetailView(session: session)
        } else if store.visibleMetas.isEmpty {
            MeetingsEmptyState(
                onRecord: { Task { await startRecording() } },
                onImport: { Task { await importFile() } },
                permissionMessage: permissionMessage
            )
        } else {
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "rectangle.stack",
                description: Text("Choose a meeting from the list."))
        }
    }

    private func consumePendingShowLive() {
        guard state.pendingShowLive else { return }
        state.pendingShowLive = false
        openLive()
    }

    /// Give the window back to the recording in progress.
    private func openLive() {
        guard let live = liveSession else { return }
        selectedID = live.id
        scope = nil
    }

    private func session(for id: UUID) -> MeetingSession? {
        if let cached = sessionCache.byID[id] { return cached }
        guard let meta = store.meta(id: id) else { return nil }
        let s = MeetingSession(from: meta)
        sessionCache.byID[id] = s
        pruneSessionCache(keeping: id)
        return s
    }

    /// Keep the session cache bounded. Each cached `MeetingSession` is an
    /// @Observable that retains its recorder objects; left unbounded the cache
    /// accreted one per meeting ever opened for the window's lifetime. We keep
    /// only what's actually in use — the live/processing session and the one
    /// just requested (which the detail pane is about to render) — and drop the
    /// rest. Evicted sessions are recreated from disk on demand (their state is
    /// fully persisted), so nothing is lost. Runs only on a cache miss (an
    /// insert), so it doesn't churn on every redraw.
    private func pruneSessionCache(keeping id: UUID) {
        let liveID = liveSession?.id
        sessionCache.byID = sessionCache.byID.filter { key, session in
            key == id || key == liveID || session.isLive || session.isProcessing
        }
    }

    /// The session backing the detail pane right now, but only when it's a
    /// finished meeting the Share menu can act on. Mirrors `detail`'s selection
    /// logic so the toolbar's Share button tracks what's actually on screen.
    /// The meeting currently shown in the detail pane, whatever its state.
    /// Used by actions that work regardless of progress (opening its folder),
    /// unlike `shareableSession`, which also requires there to be something to
    /// copy/export.
    private var currentSession: MeetingSession? {
        guard let id = selectedID else { return nil }
        if let live = liveSession, id == live.id { return live }
        return session(for: id)
    }

    private var shareableSession: MeetingSession? {
        guard let candidate = currentSession else { return nil }
        switch candidate.state {
        case .ready, .idle, .summarising: return candidate
        default: return nil
        }
    }

    /// Copy / export menu. Tab-independent, so it lives in the window toolbar
    /// (above the content) rather than over the reading surface. "Copy notes"
    /// gives the markdown notes; "Copy transcript" / "Export…" use the diarized
    /// transcript read from disk on demand.
    @ViewBuilder
    private func shareMenu(for session: MeetingSession) -> some View {
        let meta = session.meta
        Menu {
            Button { copyNotes(meta) } label: {
                Label("Copy notes", systemImage: "doc.on.doc")
            }
            .disabled(meta.notes == nil)
            Button { copyTranscript(session) } label: {
                Label("Copy transcript", systemImage: "text.quote")
            }
            Divider()
            Button { exportMeeting(session) } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            if (meta.screenshotCount ?? 0) > 0 {
                Button { exportMeetingBundle(session) } label: {
                    Label("Export with screenshots…", systemImage: "photo.on.rectangle")
                }
            }
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.visible)
        .help("Copy or export this meeting's notes and transcript.")
    }

    /// Open the meeting's folder in Finder — the synced folder holding
    /// meta.json plus the readable notes.md / transcript.md / pad.md and the
    /// live-* mirror files. (The audio tracks live in a separate local folder.)
    private func showInFinder(_ session: MeetingSession) {
        NSWorkspace.shared.open(MeetingStorage.folder(for: session.id))
    }

    private func copyNotes(_ meta: MeetingMeta) {
        guard let notes = meta.notes else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(meta.title)\n\n\(notes.markdown)", forType: .string)
    }

    private func copyTranscript(_ session: MeetingSession) {
        guard let t = MeetingStorage.readTranscript(for: session.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            MeetingExporter.transcriptMarkdown(transcript: t, meta: session.meta),
            forType: .string
        )
    }

    private func exportMeeting(_ session: MeetingSession) {
        let meta = session.meta
        let panel = NSSavePanel()
        panel.title = "Export meeting"
        panel.message = "Choose where to save this meeting."
        panel.allowedContentTypes = [UTType.plainText, UTType(filenameExtension: "md") ?? UTType.plainText]
        panel.canCreateDirectories = true
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeTitle).md"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let isMarkdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        let body: String
        if let t = MeetingStorage.readTranscript(for: session.id) {
            body = isMarkdown
                ? MeetingExporter.markdown(transcript: t, meta: meta)
                : MeetingExporter.plainText(transcript: t, meta: meta)
        } else if let notes = meta.notes {
            body = "# \(meta.title)\n\n\(notes.markdown)"
        } else {
            return
        }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Dictator] Meeting export failed: \(error)")
        }
    }

    /// Export a self-contained folder: the meeting's markdown (notes +
    /// transcript with screenshot links interleaved at their timestamps) plus a
    /// `screenshots/` subfolder of the images, so the relative links resolve and
    /// the bundle is portable. Reveals the folder in Finder when done.
    private func exportMeetingBundle(_ session: MeetingSession) {
        let meta = session.meta
        let safeTitle = meta.title.replacingOccurrences(of: "/", with: "-")
        let panel = NSSavePanel()
        panel.title = "Export meeting with screenshots"
        panel.message = "A folder with the meeting's markdown and screenshots will be created."
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeTitle

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let shots = MeetingStorage.readScreenshotIndex(for: meta.id)?.screenshots ?? []
        let body: String
        if let t = MeetingStorage.readTranscript(for: meta.id) {
            body = MeetingExporter.markdown(transcript: t, meta: meta, screenshots: shots)
        } else if let notes = meta.notes {
            body = "# \(meta.title)\n\n\(notes.markdown)"
        } else {
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try body.write(to: url.appendingPathComponent("\(safeTitle).md"), atomically: true, encoding: .utf8)
            if !shots.isEmpty {
                let src = MeetingStorage.screenshotsFolder(for: meta.id)
                let dst = url.appendingPathComponent("screenshots", isDirectory: true)
                try fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for shot in shots {
                    try? fm.copyItem(
                        at: src.appendingPathComponent(shot.filename),
                        to: dst.appendingPathComponent(shot.filename)
                    )
                }
            }
            NSWorkspace.shared.open(url)
        } catch {
            NSLog("[Dictator] Meeting bundle export failed: \(error)")
        }
    }

    /// Record / Stop, swapped on the live state. Extracted so the toolbar can
    /// group it with the mic picker in one glass capsule.
    @ViewBuilder
    private var recordOrStopButton: some View {
        if liveSession?.isLive == true {
            Button(role: .destructive) {
                Task {
                    await liveSession?.stopRecording(parakeetModelID: state.settings.parakeetModelID)
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.red)
            .keyboardShortcut("r", modifiers: .command)
        } else {
            Button {
                Task { await startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(liveSession?.isProcessing == true)
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    @ViewBuilder
    private var importButton: some View {
        Button {
            Task { await importFile() }
        } label: {
            Label("Import…", systemImage: "square.and.arrow.down")
        }
        .disabled(liveSession?.isLive == true)
    }

    private func startRecording() async {
        // Parakeet is a hard dependency for meetings — gate before we touch
        // permissions or the recorder so the user gets the download prompt
        // rather than a stalled live-notes pane mid-recording.
        guard ensureParakeetReady() else { return }
        guard ensureMeetingLLMReady() else { return }
        // Probe permission first so the user gets the deep-link banner
        // before we try to bring up the CATap recorder.
        switch await AudioRecordingPermission.probe() {
        case .granted:
            permissionMessage = nil
        case .notGranted:
            permissionMessage = "Dictator needs System Audio Recording permission. Open System Settings, then come back."
            return
        }
        // Straight to recording — no pre-record ceremony. The coach
        // checklist is built (or skipped) from inside the meeting via the
        // Key points card's quick-add and "Add from set" menu.
        let session = MeetingSession(forLiveRecording: UUID())
        liveSession = session
        selectedID = session.id
        scope = nil
        // The companion follows this; a new recording brings it back even if
        // it was hidden during the last one.
        state.liveSession = session
        state.companionDismissed = false
        sessionCache.byID[session.id] = session
        let preferred = AudioDeviceManager.shared.preferredConnectedDevice()
        await session.startRecording(preferredMicDevice: preferred)
    }

    private func importFile() async {
        guard ensureParakeetReady() else { return }
        guard ensureMeetingLLMReady() else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = MeetingImporter.acceptedContentTypes
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        await importFiles([url])
    }

    /// Shared entry point for both the Import… NSOpenPanel and the
    /// drag-and-drop zones. Imports each URL serially so we don't try to
    /// load + run the ASR model in parallel across multiple files, and
    /// leaves the last-imported session selected when the batch is done.
    private func importFiles(_ urls: [URL]) async {
        guard ensureParakeetReady() else { return }
        guard ensureMeetingLLMReady() else { return }
        for url in urls {
            // Build the shell synchronously (fast — just reads file
            // metadata). The session lands in `.importing(0)` so the
            // detail pane immediately shows a progress bar instead of
            // beach-balling for the duration of the AAC re-encode.
            let session: MeetingSession
            do {
                session = try MeetingImporter.makeShellSession(from: url)
            } catch {
                permissionMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                continue
            }
            sessionCache.byID[session.id] = session
            selectedID = session.id
            scope = nil
            liveSession = session
            let modelID = state.settings.parakeetModelID
            // runImport drives off-main re-encode → .captured → processor.
            await session.runImport(from: url, parakeetModelID: modelID)
        }
    }
}

/// The demo-mode indicator, pinned above the meetings list. Deliberately small
/// and orange rather than a full banner: it has to be unmistakable in a screen
/// recording (so a viewer knows the meetings aren't real) without dominating
/// the shot it appears in. Mirrors the pill in Dictator's menu-bar dropdown,
/// and carries the same way out.
private struct DemoSidebarPill: View {
    private let demo = MeetingsDemoMode.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Demo")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("showing fictional content")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
            Button("Turn off") { demo.setOn(false) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// Compact glass "Sync" chip at the foot of the sidebar. Replaces the old
/// always-on two-line explainer strip — one tappable glass capsule, with the
/// full sync story moved into a popover, so the meetings list keeps the room.
private struct SyncFooterChip: View {
    @State private var showInfo = false

    var body: some View {
        HStack {
            Button { showInfo.toggle() } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.medium))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .popover(isPresented: $showInfo, arrowEdge: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Notes & transcripts sync · audio stays local", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.semibold))
                    Text("Each meeting's notes and transcript are saved in your synced Dictator folder (Settings → General → Synced folder), so they appear on all your Macs. The audio recordings are large, so they stay on the Mac that recorded them — you'll see the notes and transcript everywhere, with playback on the recording Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 320)
                .padding(14)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// What the detail pane shows when nothing is selected and no recording
/// is in flight. Two big affordances + optional permission banner.
struct MeetingsEmptyState: View {
    let onRecord: () -> Void
    let onImport: () -> Void
    let permissionMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "person.2.wave.2")
                    .font(.system(size: 56, weight: .regular))
                    .foregroundStyle(.tint)
                Text("No meeting open")
                    .font(.title2.weight(.semibold))
                Text("Start a new recording, import an audio file, or drag one anywhere onto this window to get a transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: onRecord) {
                    Label("Record", systemImage: "record.circle.fill")
                        .frame(minWidth: 100)
                }
                .controlSize(.large)
                .buttonStyle(.glassProminent)
                Button(action: onImport) {
                    Label("Import…", systemImage: "square.and.arrow.down")
                        .frame(minWidth: 100)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
            }

            if let msg = permissionMessage {
                VStack(spacing: 8) {
                    Text(msg)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        AudioRecordingPermission.openSystemSettings()
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
                .padding(.horizontal, 40)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The old always-visible dashed `SidebarDropZone` is gone — the whole window
// is now a drop target (`.dropDestination` on the root, with `MeetingDropOverlay`
// shown only while dragging), so the sidebar keeps the room it used to occupy.
