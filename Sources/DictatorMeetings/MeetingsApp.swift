import SwiftUI
import AppKit
import Sparkle

/// Sparkle's lifecycle holder for the Meetings app. Dictator keeps its own copy
/// (SettingsShell.swift) — the two processes each run their own updater against
/// their own appcast feed (`SUFeedURL` in project.yml), so this is a copy rather
/// than a shared type in DictatorMac: sharing it would give one process's holder
/// to both, and there's no state worth sharing anyway.
@MainActor
enum SparkleUpdater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// Dictator Meetings — the standalone meeting recorder / note-taker.
///
/// Unlike Dictator (an `LSUIElement` accessory app driven from the menu bar),
/// this is a regular windowed app: it opens its window at launch and has a Dock
/// icon. The menu-bar item is an optional status affordance, not the app's only
/// surface — it's there so a recording is visibly in progress and startable /
/// stoppable while the window is buried, which is the normal state mid-call.
@main
struct DictatorMeetingsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = MeetingsAppState.shared

    /// Read once at launch rather than bound live: `MenuBarExtra(isInserted:)`
    /// tears the status item down and rebuilds it on every change, and the
    /// setting's footnote promises "takes effect on the next launch" for
    /// exactly that reason.
    @State private var menuBarInserted = MeetingsAppState.shared.settings.showMenuBarStatus

    init() {
        // Storage must be pointed at the synced folder before the Meetings
        // window's first scan, and SwiftUI can show that window before the
        // AppDelegate's launch hook fires. `bootstrap()` re-calls this as a
        // no-op.
        MeetingsAppState.shared.prepareStorage()
    }

    var body: some Scene {
        // A single `Window`, NOT a `WindowGroup`: Meetings is one-per-app, so
        // reopening re-fronts the existing window instead of spawning a
        // duplicate, and there's no ⌘N "new window" command. The live
        // recording / detail-pane state lives in this window's `@State`, which
        // only makes sense as a single instance anyway.
        Window("Meetings", id: "meetings") {
            MeetingsRootHost()
                // 1000 = sidebar max (320) + the detail's compressed width +
                // the Details inspector's 240pt minimum, with room for the
                // dividers. At the old 760 the three columns could not all be
                // satisfied at once, and rather than collapsing one, SwiftUI
                // and AppKit traded min-size updates until the window
                // exhausted its Update Constraints passes and the app aborted.
                .frame(minWidth: 1000, minHeight: 480)
                .environment(state)
        }
        .defaultSize(width: 1280, height: 760)
        .handlesExternalEvents(matching: ["meetings", "record"])
        .commands {
            // The notes assistant. In Dictator this rode the global assistant
            // hotkey (routed by focus); here it's a plain in-app command,
            // which is both simpler and honest — this app has no global
            // hotkeys and asks for no Accessibility grant.
            CommandMenu("Assistant") {
                Button("Ask About These Notes") {
                    MeetingsAppState.shared.meetingAssistant?.toggleFromCommand()
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                // Deliberately never disabled. `meetingAssistant` is a weak,
                // observation-ignored registration made by the notes view
                // while it's on screen, so a `.disabled(...)` reading it
                // wouldn't re-evaluate when the view registers — the item
                // would sit greyed out forever. `toggleFromCommand` already
                // no-ops when there's nothing to act on.
            }
        }

        // A plain SwiftUI `Settings` scene, unlike Dictator's AppKit-owned
        // window: Meetings has a handful of tabs and no sidebar, so the scene's
        // limitations (dead controls in a faked titlebar strip) don't bite.
        Settings {
            MeetingsSettingsView()
                .environment(state)
        }

        MenuBarExtra(isInserted: $menuBarInserted) {
            MeetingsMenuBarContent()
                .environment(state)
        } label: {
            // Red while recording — the whole point of the status item is
            // being able to see, from anywhere, that a meeting is being
            // captured.
            if state.isRecordingMeeting {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .red)
            } else {
                Image(systemName: "person.2.wave.2")
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Wraps `MeetingsRootView` with the two things only a view can supply: the
/// SwiftUI environment actions non-SwiftUI surfaces need (the URL handler, the
/// menu-bar item), and the first-run sheet.
private struct MeetingsRootHost: View {
    @Environment(MeetingsAppState.self) private var state
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showingOnboarding = false

    var body: some View {
        MeetingsRootView()
            .onAppear {
                MeetingsAppState.shared.openSettingsAction = { openSettings() }
                MeetingsAppState.shared.openMeetingsWindowAction = { openWindow(id: "meetings") }
                if !state.settings.hasCompletedOnboarding { showingOnboarding = true }
            }
            .sheet(isPresented: $showingOnboarding) {
                MeetingsOnboardingSheet {
                    showingOnboarding = false
                    // Set whether they completed every step or skipped: the
                    // sheet is a nudge, not a gate, and the per-action gates
                    // in the recording flow still catch anything missing.
                    // Ambushing them with it on every launch would not.
                    MeetingsAppState.shared.settings.hasCompletedOnboarding = true
                    MeetingsAppState.shared.save()
                }
                .environment(state)
            }
    }
}

/// The menu-bar status item's menu: start / stop a capture and get back to the
/// window, without hunting for the app in the Dock mid-call.
private struct MeetingsMenuBarContent: View {
    @Environment(MeetingsAppState.self) private var state

    var body: some View {
        if state.isRecordingMeeting {
            Button("Stop Recording") {
                state.requestStopRecording()
                state.openMeetingsWindowAction?()
            }
        } else {
            Button("Record Meeting") {
                // Same one-shot flag the URL handler uses: set it, THEN open
                // the window, so `MeetingsRootView` consumes it in one place
                // and there's no "the window doesn't exist yet" race.
                state.pendingMeetingRecording = true
                state.openMeetingsWindowAction?()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Divider()
        Button("Open Meetings") {
            state.openMeetingsWindowAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Settings…") {
            state.openSettingsAction?()
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit Dictator Meetings") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The coach's notch island. Created here (not in a view) because it
    /// outlives the window: the strip's whole purpose is to be visible with
    /// the meetings window buried behind the call.
    private var coachIsland: CoachIslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard, same as Dictator's. Two copies with the same
        // bundle ID can run side by side when they live at different paths —
        // the installed ~/Applications build alongside a DerivedData ⌘R build,
        // say — because Launch Services only dedupes launches by path. Each
        // instance would record and write notes independently. Defer to
        // whoever's already running and bail before bootstrapping anything.
        if let existing = Self.alreadyRunningInstance() {
            NSLog("[DictatorMeetings] Another instance (pid \(existing.processIdentifier)) is already running; quitting this one.")
            NSApp.terminate(nil)
            return
        }

        // Start Sparkle's background update schedule (first touch creates the
        // controller with `startingUpdater: true`).
        _ = SparkleUpdater.controller

        // Settings load (with the one-time import from Dictator on first run),
        // meeting storage migration + crash recovery, provider registry, model
        // preload. Everything the app does afterwards assumes this has run.
        MeetingsAppState.shared.bootstrap()

        coachIsland = CoachIslandController(state: MeetingsAppState.shared)
    }

    /// Routes `dictator-meetings://…` URLs. Two hosts: `record` starts a
    /// capture (same one-shot flag the menu-bar item sets), `meetings` just
    /// fronts the window. Handled here rather than with `.onOpenURL` so it
    /// works before any scene has rendered.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "dictator-meetings" else { continue }
            switch url.host?.lowercased() {
            case "record":
                MeetingsAppState.shared.pendingMeetingRecording = true
                NSApp.activate(ignoringOtherApps: true)
                MeetingsAppState.shared.openMeetingsWindowAction?()
            case "meetings", nil:
                NSApp.activate(ignoringOtherApps: true)
                MeetingsAppState.shared.openMeetingsWindowAction?()
            case "settings":
                NSApp.activate(ignoringOtherApps: true)
                MeetingsAppState.shared.openSettingsAction?()
            default:
                NSLog("[DictatorMeetings] Ignoring unknown URL: \(url.absoluteString)")
            }
        }
    }

    /// With the status item on, closing the window is "get out of my way", not
    /// "quit" — the item is how you get back, and a recording may still be
    /// running. With it off the window is the only surface, so closing it is a
    /// quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MeetingsAppState.shared.settings.showMenuBarStatus
    }

    /// The already-running Dictator Meetings instance, if any, excluding this
    /// process. Matches on bundle identifier so it catches a copy launched from
    /// a different path — Launch Services only dedupes by path, so those
    /// otherwise run side by side.
    private static func alreadyRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let myPID = NSRunningApplication.current.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID }
    }
}
