import SwiftUI
import AppKit
import Combine
import AVFoundation
import KeyboardShortcuts

/// General: the settings that aren't about a single flow — permissions, who
/// you are, the instruction line that applies everywhere, delivery behaviour,
/// the HUD style, the sound set, the Scratchpad, where synced data lives, and
/// the per-Mac performance trade-offs.
///
/// The dictation and assistant hotkeys deliberately live with their flows
/// (Dictation → Modes, Assistant) rather than here.
struct GeneralPane: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var s = state
        Form {
            Section("Permissions") {
                AccessibilityStatusRow()
                MicrophoneStatusRow()
            }

            Section {
                TextField("Name", text: $s.settings.userName, prompt: Text("Rob Gough"))
                    .onSubmit { state.save() }
                    .onChange(of: s.settings.userName) { _, _ in state.save() }
            } header: {
                Text("Your name")
            } footer: {
                SectionFootnote("Used for spelling your name and signing assistant drafts.")
            }

            Section {
                // Plain (not monospace) and borderless: this is a sentence or
                // two of preference, not a prompt. Full prompts live in sheets.
                InstructionsField(
                    "e.g. Always use British spelling",
                    text: $s.settings.globalPromptAddendum,
                    onChange: { state.save() }
                )
            } header: {
                Text("AI instructions")
            } footer: {
                SectionFootnote("Applies to every dictation style and the assistant.")
            }

            Section {
                Toggle("Paste into the focused app", isOn: $s.settings.pasteAutomatically)
                    .onChange(of: s.settings.pasteAutomatically) { _, _ in state.save() }
                Toggle("Tap the hotkey to start and stop", isOn: $s.settings.hotkeyTapToToggleEnabled)
                    .onChange(of: s.settings.hotkeyTapToToggleEnabled) { _, _ in state.save() }
                    .help("Applies to both hotkeys. Holding still works as push-to-talk.")
                Picker("While dictating", selection: $s.settings.audioInterruption) {
                    ForEach(AudioInterruption.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .onChange(of: s.settings.audioInterruption) { _, _ in state.save() }
                .help("Not synced between Macs. Pausing asks for one-time Automation permission per app.")
            } header: {
                Text("Behaviour")
            } footer: {
                SectionFootnote("Auto ducks the output when it can, otherwise pauses Spotify or Music.")
            }

            Section {
                HUDStyleGallery()
            } header: {
                Text("HUD")
            } footer: {
                SectionFootnote("Not synced between Macs.")
            }

            Section {
                Toggle("Play sounds", isOn: $s.settings.playSounds)
                    .onChange(of: s.settings.playSounds) { _, _ in state.save() }
                SoundThemeGallery()
            } header: {
                Text("Sounds")
            } footer: {
                SectionFootnote("Press play to hear a set.")
            }

            Section {
                Toggle("Scratchpad", isOn: $s.settings.scratchpadEnabled)
                    .onChange(of: s.settings.scratchpadEnabled) { _, _ in state.save() }
                if s.settings.scratchpadEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleScratchpad)
                        Button("Reset") {
                            KeyboardShortcuts.reset(.toggleScratchpad)
                        }
                        .controlSize(.small)
                    }
                    Picker("Width", selection: $s.settings.scratchpadWidth) {
                        ForEach(ScratchpadWidth.allCases) { width in
                            Text(width.label).tag(width)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: s.settings.scratchpadWidth) { _, _ in
                        state.save()
                        state.scratchpadController?.relayoutIfVisible()
                    }
                }
            } header: {
                Text("Scratchpad")
            } footer: {
                SectionFootnote("A floating note on a shortcut, saved to your synced folder.")
            }

            Section {
                SyncedFolderRow()
            } header: {
                Text("Synced folder")
            } footer: {
                SectionFootnote("Settings, dictionary and history follow you between Macs.")
            }

            Section {
                Toggle("Pre-load models at launch", isOn: $s.settings.preloadModelsOnLaunch)
                    .onChange(of: s.settings.preloadModelsOnLaunch) { _, on in
                        state.save()
                        if on { state.preloadModels() }
                    }
                Toggle("Share the loaded model with Dictator Meetings", isOn: $s.settings.shareLoadedModelEnabled)
                    .onChange(of: s.settings.shareLoadedModelEnabled) { _, _ in state.save() }
                    .help("Lets Dictator Meetings write notes with the model this app already has in memory. Dictation always takes priority.")
            } header: {
                Text("Performance")
            } footer: {
                SectionFootnote("Not synced between Macs. Pre-loading keeps ~3 GB resident so the first dictation is instant.")
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
    }
}

/// Row that shows where Dictator's synced data lives and lets the user
/// point it at a different folder. Default is `~/Documents/Dictator/`. The
/// folder holds `settings.json`, `vocabulary.json`, `history.json`, and
/// `conversations.json` — anything that travels between a user's Macs.
private struct SyncedFolderRow: View {
    @Environment(AppState.self) private var state
    @State private var store = VocabularyStore.shared

    var body: some View {
        @Bindable var s = state
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(currentDirectory.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Choose…") { chooseLocation() }
                    .controlSize(.small)
                if s.settings.syncedDirectoryPath != nil {
                    Button("Reset") { resetLocation() }
                        .controlSize(.small)
                }
            }
            if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var currentDirectory: URL {
        if let path = state.settings.syncedDirectoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return SyncedStorage.defaultDirectory
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder for Dictator's synced data. Existing files will be copied across so nothing is lost."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocate(to: url)
    }

    private func resetLocation() {
        relocate(to: SyncedStorage.defaultDirectory)
    }

    /// Copies every known synced file to the new location, updates the
    /// settings pointer, then tells VocabularyStore to re-anchor its file
    /// handle (it owns a vnode watcher that needs to re-bind). The settings
    /// file itself is rewritten on the next `state.save()`.
    private func relocate(to newDirectory: URL) {
        let old = currentDirectory
        SyncedStorage.relocateContents(from: old, to: newDirectory)
        // Update the path setting. Save() routes settings.json to the new
        // location automatically (it reads syncedDirectoryPath when
        // resolving the write URL).
        if newDirectory == SyncedStorage.defaultDirectory {
            state.settings.syncedDirectoryPath = nil
        } else {
            state.settings.syncedDirectoryPath = newDirectory.path
        }
        state.save()
        store.relocate(to: newDirectory)
        // Re-point the Scratchpad note too — its file was copied across by
        // relocateContents above; this reloads the model from the new folder.
        state.scratchpadController?.relocate(to: newDirectory)
    }
}

/// One line of status plus (when there's something to do) one button. The
/// consequence of *not* granting lives in a tooltip, not a caption stack.
private struct AccessibilityStatusRow: View {
    @State private var granted: Bool = TextInjector.hasAccessibilityPermission()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Text("Accessibility")
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.caption)
            Text(granted ? "Granted" : "Not granted")
                .foregroundStyle(.secondary)
            Spacer()
            if !granted {
                // Two-step gesture in one click: trigger the AX trust prompt
                // (which adds Dictator to the Accessibility list in macOS's
                // database — without this the user can't find us in
                // System Settings), then surface the Settings page so they
                // have somewhere to flip the toggle.
                Button("Enable") {
                    TextInjector.requestAccessibilityPrompt()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .help(granted
              ? "Dictator can paste into the focused app and swallow the Tab key while cycling modes."
              : "Without it Dictator copies to the clipboard instead of pasting, and Tab cycling is off.")
        .onReceive(pollTimer) { _ in
            granted = TextInjector.hasAccessibilityPermission()
        }
    }
}

private struct MicrophoneStatusRow: View {
    @State private var status: AVAuthorizationStatus = MicPermission.status()
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Text("Microphone")
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.caption)
            Text(statusLabel)
                .foregroundStyle(.secondary)
            Spacer()
            actionButton
        }
        .help("Dictator can't record without microphone access.")
        .onReceive(pollTimer) { _ in
            status = MicPermission.status()
        }
    }

    private var statusIcon: String {
        switch status {
        case .authorized: "checkmark.seal.fill"
        case .denied, .restricted: "exclamationmark.triangle.fill"
        case .notDetermined: "questionmark.circle.fill"
        @unknown default: "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized: .green
        case .denied, .restricted: .orange
        case .notDetermined: .secondary
        @unknown default: .secondary
        }
    }

    private var statusLabel: String {
        switch status {
        case .authorized: "Granted"
        case .denied, .restricted: "Denied"
        case .notDetermined: "Not requested"
        @unknown default: "Unknown"
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch status {
        case .notDetermined:
            // Triggers the OS prompt + registers Dictator in the Microphone
            // privacy list. Without this, the user only sees Dictator in
            // System Settings after the first dictation lazily fires the
            // request — bad first-run UX.
            Button("Request") {
                MicPermission.request { granted in
                    Task { @MainActor in
                        status = MicPermission.status()
                        // Belt + braces: a denial from the OS prompt still
                        // leaves us in `.denied`, where the user needs the
                        // Settings page to undo it.
                        if !granted {
                            openMicrophoneSettings()
                        }
                    }
                }
            }
            .controlSize(.small)
        case .denied, .restricted:
            Button("Open Settings") { openMicrophoneSettings() }
                .controlSize(.small)
        case .authorized:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
