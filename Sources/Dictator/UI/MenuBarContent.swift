import SwiftUI
import AppKit
import AVFoundation
import KeyboardShortcuts

struct MenuBarContent: View {
    @Environment(AppState.self) private var state
    @State private var history = DictationHistory.shared
    @State private var modelManager = ModelManager.shared
    private let demo = DemoMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if demo.isOn { demoBanner }
            header
            Divider()
            statusRow

            // Mode section — only shown once the user has more than the
            // built-in Quick. One mode = nothing to pick between, and no mode
            // an app could be switched to.
            if state.settings.modes.count > 1 {
                Divider()
                MenuModeSection()
            }

            Divider()
            MenuModelsSection()

            if !demo.historyIsEmpty(real: history.records) {
                Divider()
                MenuRecentSection(records: Array(demo.history(real: history.records).prefix(5)))
            }

            // Chat gets its own full-width row above the Meetings one. It's a
            // destination, not a setting, and it's the only entry here that
            // opens a window you sit in front of.
            //
            // It replaced a list of recent assistant conversations that used to
            // sit above the dictation history. Once Assistant Mode and chat
            // became one store, that list was a second, worse thread browser
            // shown in a popover you have to hold open — the sidebar in the
            // chat window is the one place threads live now.
            Divider()
            Button {
                ChatWindowController.shared.show()
            } label: {
                Label("Chat…", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(MenuRowStyle())
            .font(.system(size: 13, weight: .medium, design: .rounded))

            // Journal sits under Chat and above Meetings: all three are
            // destinations you sit in front of, and this is the only one that
            // shows you what the journal hotkey has been collecting.
            Divider()
            Button {
                JournalWindowController.shared.show()
            } label: {
                Label("Journal…", systemImage: "book.closed")
            }
            .buttonStyle(MenuRowStyle())
            .font(.system(size: 13, weight: .medium, design: .rounded))

            // Its own full-width row, and only when the app is actually
            // installed: squeezed into the footer next to Settings and Quit
            // the label wrapped, and users without Dictator Meetings have no
            // use for it at all.
            if meetingsInstalled {
                Divider()
                Button {
                    openDictatorMeetings()
                } label: {
                    Label("Open Dictator Meetings…", systemImage: "person.2.wave.2")
                }
                .buttonStyle(MenuRowStyle())
                .font(.system(size: 13, weight: .medium, design: .rounded))
            }

            // Development builds only (see `BuildStamp`): which build is this,
            // and is it the one I just made? Nil — and so absent entirely — in
            // anything shipped.
            if let build = BuildStamp.label {
                Divider()
                Label(build, systemImage: "hammer")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            Divider()
            // Wider spacing than it looks like it needs: each button's hover
            // highlight reaches 6pt past its label.
            HStack(spacing: 16) {
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                // The wizard exists to walk you through the things that
                // *must* be configured for dictation to work. Once mic is
                // granted and at least one model in the active engine is
                // installed, there's nothing left to set up — hide the
                // entry so it stops cluttering the menu.
                if needsSetup {
                    Button {
                        state.showOnboarding()
                    } label: {
                        Label("Setup…", systemImage: "sparkles")
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(MenuRowStyle(fillsWidth: false))
            .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            // Recompute on-disk model state each time the menu opens — the
            // user may have downloaded or removed a model from Settings
            // since we last refreshed.
            modelManager.refreshCachedStates()
        }
    }

    /// Launch the separate Dictator Meetings app, or — when it isn't
    /// installed — send the user to the download page.
    ///
    /// `urlForApplication(withBundleIdentifier:)` is the only reliable way to
    /// find it: it may be in `/Applications`, `~/Applications`, or a
    /// DerivedData folder on a development Mac, and Launch Services already
    /// knows which. Launching by URL (rather than
    /// `launchApplication(withBundleIdentifier:)`) keeps the "already running"
    /// case a plain re-activation.
    private static let meetingsBundleID = "net.robgough.DictatorMeetings"

    /// Whether Dictator Meetings is installed anywhere Launch Services knows
    /// about. Evaluated on each popover render — cheap, and it means the row
    /// appears the moment the app is installed without a relaunch.
    private var meetingsInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.meetingsBundleID) != nil
    }

    private func openDictatorMeetings() {
        let bundleID = Self.meetingsBundleID
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            if let site = URL(string: "https://dictator.robgough.net/#meetings") {
                NSWorkspace.shared.open(site)
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                NSLog("[Dictator] Couldn't launch Dictator Meetings: \(error)")
            }
        }
    }

    /// True when the wizard still has something to do for the user.
    /// Mic must be authorized AND at least one model in the active
    /// transcription engine must be installed. Accessibility is optional
    /// (clipboard fallback works), and the LLM is optional too — neither
    /// blocks dictation.
    private var needsSetup: Bool {
        if MicPermission.status() != .authorized { return true }
        switch state.settings.transcriptionEngine {
        case .parakeet:
            return !ModelCatalog.parakeetModels.contains { modelManager.parakeetStates[$0.id] == .ready }
        case .whisper:
            return !ModelCatalog.whisperModels.contains { modelManager.whisperStates[$0.id] == .ready }
        }
    }

    /// The one place demo mode is visible as itself: a small pill at the top of
    /// the dropdown, with a way out. Everything else in the UI looks exactly as
    /// it normally does, so a recording doesn't advertise that it's staged.
    private var demoBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "theatermasks.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("Demo")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Text("showing fictional content")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictator")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                VStack(alignment: .leading, spacing: 1) {
                    HotkeyHint(
                        label: "Dictate",
                        keys: Self.hotkeyDisplay(name: .toggleDictation, mode: state.settings.triggerMode)
                    )
                    HotkeyHint(
                        label: "Assistant",
                        keys: Self.hotkeyDisplay(name: .toggleAssistant, mode: state.settings.assistantTriggerMode)
                    )
                }
            }
            Spacer()
        }
    }

    /// Compact human-readable form of a hotkey for the menu-bar header.
    /// For keyboard combinations we ask KeyboardShortcuts for the current
    /// `Shortcut`'s description (e.g. "⌥⌘D"). For modifier-only triggers we
    /// render side + symbol (e.g. "Right ⌥") since the binder distinguishes
    /// left/right by virtual key code.
    private static func hotkeyDisplay(name: KeyboardShortcuts.Name, mode: TriggerMode) -> String {
        switch mode {
        case .keyboardShortcut:
            return KeyboardShortcuts.getShortcut(for: name)?.description ?? "Not set"
        case .leftOption:    return "Left ⌥"
        case .rightOption:   return "Right ⌥"
        case .leftCommand:   return "Left ⌘"
        case .rightCommand:  return "Right ⌘"
        case .leftControl:   return "Left ⌃"
        case .rightControl:  return "Right ⌃"
        case .leftShift:     return "Left ⇧"
        case .rightShift:    return "Right ⇧"
        case .fn:            return "fn"
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: state.pipeline.state.iconName)
                .foregroundStyle(.secondary)
            Text(statusText)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            if state.pipeline.state.isActive {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var statusText: String {
        switch state.pipeline.state {
        case .idle: "Idle"
        case .capturingSelection: "Reading selection…"
        case .warmingUp: "Connecting microphone…"
        case .recording(_, let kind, _):
            switch kind {
            case .dictation: "Listening…"
            case .assistant: "Listening for instruction…"
            case .journal:   "Listening for your journal…"
            }
        case .transcribing: "Transcribing…"
        case .readingScreen(.spellings): "Checking spellings…"
        case .readingScreen(.content): "Reading screen…"
        case .formatting: "Formatting…"
        case .fixingGrammar: "Polishing…"
        case .restructuring: "Paragraphs…"
        case .translating: "Translating…"
        case .assisting: "Thinking…"
        case .compacting: "Summarising earlier turns…"
        case .done(_, let pasted, _):
            if state.pipeline.lastDeliveryWasJournal { "Saved to your journal" }
            else { pasted ? "Pasted" : "Copied to clipboard" }
        case .failed(let m): m
        }
    }

}

private struct HotkeyHint: View {
    let label: String
    let keys: String

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(keys)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
    }
}
