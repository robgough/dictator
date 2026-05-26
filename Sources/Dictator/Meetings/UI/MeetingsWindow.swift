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
        }
    }

    @ViewBuilder
    private var sidebar: some View {
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
        // before we try to bring up SCStream.
        switch await ScreenRecordingPermission.probe() {
        case .granted:
            permissionMessage = nil
        case .notGranted:
            permissionMessage = "Dictator needs Screen Recording permission. Open System Settings, then come back."
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
        panel.allowedContentTypes = [
            UTType.audio,
            UTType(filenameExtension: "m4a") ?? .audio,
            UTType(filenameExtension: "wav") ?? .audio,
            UTType(filenameExtension: "mp3") ?? .audio,
            UTType(filenameExtension: "aac") ?? .audio,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "caf") ?? .audio,
        ]
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            let session = try MeetingImporter.makeSession(from: url)
            openSessions[session.id] = session
            selectedID = session.id
            liveSession = session
            let modelID = state.settings.parakeetModelID
            await session.runProcessor(parakeetModelID: modelID)
        } catch {
            permissionMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
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
                Text("Start a new recording or import an audio file to get a transcript.")
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
                        ScreenRecordingPermission.openSystemSettings()
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
