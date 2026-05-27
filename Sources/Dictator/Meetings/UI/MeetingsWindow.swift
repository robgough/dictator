import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Root view of the Meetings window. NavigationSplitView with a sidebar
/// listing every saved meeting and a detail pane that renders either a
/// live recording, a processing run, or a finished transcript.
struct MeetingsRootView: View {
    @Environment(AppState.self) private var state
    @State private var store = MeetingsStore.shared
    @State private var selectedID: UUID?
    /// One session per selected meeting. Cached so the detail view doesn't
    /// rebuild its @Observable owner on every redraw — and so a live
    /// session in flight keeps its state across selection changes.
    @State private var liveSession: MeetingSession?
    @State private var openSessions: [UUID: MeetingSession] = [:]
    @State private var showingPermissionBanner = false
    @State private var permissionMessage: String?
    @State private var deviceManager = AudioDeviceManager.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Meetings")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                micPicker
                Button {
                    Task { await startRecording() }
                } label: {
                    Label("Record", systemImage: "record.circle")
                }
                .disabled(liveSession?.state.isLive == true || liveSession?.state.isProcessing == true)
                Button {
                    Task { await importFile() }
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
            }
        }
        .onAppear {
            store.refresh()
            consumePendingRecordingRequest()
        }
        // Catches the case where the Meetings window is *already* open
        // when the user hits "Record meeting" in the menu bar — onAppear
        // won't fire again, but the @Observable flag flip does.
        .onChange(of: state.pendingMeetingRecording) { _, isPending in
            if isPending { consumePendingRecordingRequest() }
        }
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
        if liveSession?.state.isLive == true || liveSession?.state.isProcessing == true {
            return
        }
        Task { await startRecording() }
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

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.metas.isEmpty {
                // SwiftUI renders the empty state in the detail pane; the
                // sidebar collapses to a hint.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Meetings")
                        .font(.headline)
                    Text("No meetings yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MeetingSidebarList(selection: $selectedID, metas: store.metas) { id in
                    store.delete(id: id)
                    if selectedID == id { selectedID = nil }
                    openSessions.removeValue(forKey: id)
                }
                .frame(maxHeight: .infinity)
            }
            SidebarDropZone { urls in
                handleDroppedURLs(urls)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let live = liveSession, live.state.isLive || live.state.isProcessing {
            MeetingDetailView(session: live)
        } else if let id = selectedID, let session = session(for: id) {
            MeetingDetailView(session: session)
        } else {
            MeetingsEmptyState(
                onRecord: { Task { await startRecording() } },
                onImport: { Task { await importFile() } },
                permissionMessage: permissionMessage
            )
        }
    }

    private func session(for id: UUID) -> MeetingSession? {
        if let cached = openSessions[id] { return cached }
        guard let meta = store.meta(id: id) else { return nil }
        let s = MeetingSession(from: meta)
        openSessions[id] = s
        return s
    }

    /// Toolbar menu showing the currently-active mic and letting the user
    /// promote any connected device. Selecting one rewrites
    /// `AudioDeviceManager.knownDevices` so both dictation and the next
    /// meeting record pick it up — there's only ever one "preferred mic"
    /// per user, kept consistent across both flows.
    @ViewBuilder
    private var micPicker: some View {
        let isRecording = liveSession?.state.isLive == true
        Menu {
            ForEach(deviceManager.connectedDevices) { device in
                Button {
                    deviceManager.promote(uid: device.uid)
                } label: {
                    if device.uid == deviceManager.preferredConnectedDevice()?.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
            Divider()
            Button {
                deviceManager.refresh()
            } label: {
                Label("Refresh devices", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mic")
                Text(deviceManager.activeInputDeviceName())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help(isRecording
              ? "Changing input applies to your next meeting."
              : "Choose which microphone the next meeting records from.")
    }

    private func startRecording() async {
        // Probe permission first so the user gets the deep-link banner
        // before we try to bring up the CATap recorder.
        switch await AudioRecordingPermission.probe() {
        case .granted:
            permissionMessage = nil
        case .notGranted:
            permissionMessage = "Dictator needs System Audio Recording permission. Open System Settings, then come back."
            return
        }
        let session = MeetingSession(forLiveRecording: UUID())
        liveSession = session
        selectedID = session.id
        openSessions[session.id] = session
        let preferred = AudioDeviceManager.shared.preferredConnectedDevice()
        await session.startRecording(preferredMicDevice: preferred)
    }

    private func importFile() async {
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
            openSessions[session.id] = session
            selectedID = session.id
            liveSession = session
            let modelID = state.settings.parakeetModelID
            // runImport drives off-main re-encode → .captured → processor.
            await session.runImport(from: url, parakeetModelID: modelID)
        }
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
                Text("Start a new recording, import an audio file, or drag one onto the drop zone at the bottom of the sidebar to get a transcript.")
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
                .buttonStyle(.borderedProminent)
                Button(action: onImport) {
                    Label("Import…", systemImage: "square.and.arrow.down")
                        .frame(minWidth: 100)
                }
                .controlSize(.large)
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

/// Drop target pinned to the bottom of the Meetings sidebar. Dashed
/// border, downward arrow, "Drop audio to transcribe" label. Hover
/// state tints the chrome so a dragging cursor gets visual feedback
/// before the drop lands.
///
/// Uses SwiftUI's `.dropDestination(for: URL.self)` (introduced in
/// macOS 13). The older `.onDrop(of:isTargeted:)` + `NSItemProvider`
/// shape didn't fire reliably on macOS 26 — Voice Memos `.m4a` files
/// dropped from Finder never produced a URL through
/// `loadObject(ofClass: URL.self)`, so the import silently no-op'd.
/// `dropDestination(for: URL.self)` handles file-promise,
/// security-scoped, and async-loaded providers internally and yields
/// `[URL]` directly. The URL-shaped Transferable conformance accepts
/// any provider that can vend a file URL, regardless of which audio
/// UTI it advertises — `MeetingImporter.urlLooksLikeAudio(_:)` does
/// the final filter so we don't try to transcribe text files.
private struct SidebarDropZone: View {
    let onDrop: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop audio to transcribe")
                .font(.caption.weight(.medium))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        } isTargeted: { hovering in
            isTargeted = hovering
        }
        .help("Drop an audio file here to import it as a new meeting.")
    }
}
