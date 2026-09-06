import SwiftUI
import AppKit
import Sparkle

@main
struct DictatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState.shared

    // Sparkle's lifecycle lives in the `SparkleUpdater` holder (see
    // SettingsShell.swift) so the AppKit-owned Settings window can reach the
    // updater; AppDelegate touches it at launch to start the background
    // update schedule.

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
                .onOpenURL { url in handleURL(url) }
        } label: {
            // A live meeting takes priority over the dictation pipeline icon —
            // the always-visible menu bar is the user's proof a recording is
            // actually happening, even with the Meetings window closed.
            if appState.isRecordingMeeting {
                Image(systemName: "record.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .red)
            } else {
                Image(systemName: appState.pipeline.state.iconName)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        // Settings is NOT a SwiftUI `Settings` scene: the window is owned by
        // `SettingsWindowController` (SettingsShell.swift), which builds real
        // AppKit chrome — NSSplitViewController sidebar + unified NSToolbar —
        // that the scene version could only fake, with dead controls in the
        // titlebar strip to show for it.

        // Meetings ships as a runtime-gated early preview (see
        // `MeetingsFeature.swift`). The scene is registered unconditionally —
        // scene builders can't take a runtime `if` — but every entry point
        // (menu bar buttons, the deep link below) checks
        // `MeetingsFeature.isEnabled` before opening it.
        //
        // A single `Window`, NOT a `WindowGroup`: Meetings is one-per-app, so
        // `openWindow(id: "meetings")` re-fronts the existing window instead of
        // spawning a duplicate, and there's no ⌘N "new window" command. The
        // live recording / detail-pane state lives in this window's `@State`,
        // which only makes sense as a single instance anyway.
        Window("Meetings", id: "meetings") {
            MeetingsRootView()
                .environment(appState)
                // 1000 = sidebar max (320) + the detail's compressed width +
                // the Details inspector's 240pt minimum, with room for the
                // dividers. At the old 760 the three columns could not all be
                // satisfied at once, and rather than collapsing one, SwiftUI
                // and AppKit traded min-size updates until the window
                // exhausted its Update Constraints passes and the app aborted.
                .frame(minWidth: 1000, minHeight: 480)
        }
        // Roomier default so the live recording layout (three columns + the
        // shared-screen/transcript inspector) opens comfortably; the status bar
        // compresses gracefully below this, down to the 760pt minimum.
        .defaultSize(width: 1280, height: 760)
        .handlesExternalEvents(matching: ["meetings"])
    }

    /// Routes incoming `dictator://…` URLs. Three hosts handled today:
    /// `settings` opens the Settings window, `onboarding` re-shows the
    /// wizard, `meetings` opens the Meetings window. Anything else is
    /// logged and ignored.
    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "dictator" else { return }
        switch url.host?.lowercased() {
        case "settings":
            SettingsWindowController.shared.show()
        case "onboarding", "setup", "wizard":
            NSApp.activate(ignoringOtherApps: true)
            appState.showOnboarding()
        case "meetings":
            guard MeetingsFeature.isEnabled else {
                NSLog("[Dictator] dictator://meetings ignored — Meetings is off or missing a usable LLM (see Settings → Meetings)")
                return
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            appState.openMeetingsAction?()
        default:
            NSLog("[Dictator] Ignoring unknown URL: \(url.absoluteString)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var island: IslandController?
    private var scratchpad: ScratchpadController?
    // Held by the delegate so the strong reference outlives every
    // services-menu invocation. `NSApp.servicesProvider` is `weak`.
    private let learnWordProvider = LearnWordProvider()

    /// Routes `dictator://…` URLs. Two hosts handled:
    /// `dictator://settings` opens the Settings window; `dictator://onboarding`
    /// (or `setup` / `wizard`) re-shows the first-run wizard. Useful both as
    /// a deep-link target for support docs and for automation.
    ///
    /// `.onOpenURL` on a MenuBarExtra scene doesn't fire for `LSUIElement`
    /// apps, so we handle URLs here in the AppDelegate.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "dictator" else { continue }
            switch url.host?.lowercased() {
            case "settings":
                Task { @MainActor in
                    // Accessory apps can't reliably show a regular window
                    // until they flip to .regular. We bounce here and the
                    // settings-window observer (below) flips back to
                    // .accessory once the user closes it, so the dock
                    // icon doesn't persist after Settings is dismissed.
                    NSApp.setActivationPolicy(.regular)
                    SettingsWindowController.shared.show()
                }
            case "onboarding", "setup", "wizard":
                NSApp.activate(ignoringOtherApps: true)
                AppState.shared.showOnboarding()
            case "meetings":
                Task { @MainActor in
                    // Gate checked inside the hop — `MeetingsFeature.isEnabled`
                    // reads MainActor state now that it's a runtime setting.
                    guard MeetingsFeature.isEnabled else {
                        NSLog("[Dictator] dictator://meetings ignored — Meetings is off or missing a usable LLM (see Settings → Meetings)")
                        return
                    }
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    AppState.shared.openMeetingsAction?()
                }
            default:
                NSLog("[Dictator] Ignoring unknown URL: \(url.absoluteString)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard. Two copies with the same bundle ID can run
        // side by side when they live at different paths — the installed
        // ~/Applications build alongside a DerivedData ⌘R build, say —
        // because Launch Services only dedupes launches by path. Each instance
        // registers the global hotkeys and pastes independently, so the user
        // sees every dictation twice. Defer to whoever's already running and
        // bail before we bootstrap anything of our own.
        if let existing = Self.alreadyRunningInstance() {
            NSLog("[Dictator] Another instance (pid \(existing.processIdentifier)) is already running; quitting this one.")
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        // When the user closes the Settings window (which we may have
        // opened via the dictator://settings URL — and which forces
        // .regular activation to be visible), revert to .accessory so the
        // dock icon doesn't persist. Filter by title because Settings is
        // the only window whose title matches the selected tab name on
        // macOS — the other windows we create (HUD, assistant result)
        // are NSPanel with empty titles.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let win = note.object as? NSWindow else { return }
            // Settings windows are titled by the active tab ("General",
            // "Models", etc.). HUD / result windows have no title.
            let title = win.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            // Defer the policy change a tick so the window-close animation
            // doesn't race with hiding the dock icon.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        // Start Sparkle's background update schedule (first touch creates the
        // controller with `startingUpdater: true`).
        _ = SparkleUpdater.controller

        let state = AppState.shared
        // Settings is an AppKit-owned window now; the captured-action
        // indirection remains because Meetings UI and scripts call
        // `state.openSettingsAction` without importing the controller.
        state.openSettingsAction = { SettingsWindowController.shared.show() }
        island = IslandController(state: state)
        // Create the Scratchpad controller and hand it to AppState before
        // bootstrap, so the toggle hotkey bound there has a live panel to drive.
        let scratchpad = ScratchpadController()
        self.scratchpad = scratchpad
        state.scratchpadController = scratchpad
        state.bootstrap()

        // Hook up the Services menu provider. The matching NSServices
        // declaration in Info.plist is what makes "Learn Word in Dictator…"
        // appear in other apps' right-click \u{2192} Services submenu; this
        // is the object that handles the call when it fires. The
        // `NSUpdateDynamicServices()` nudge prompts pbs to re-scan the
        // bundle so a freshly-installed build's services show up without
        // requiring a logout.
        NSApp.servicesProvider = learnWordProvider
        NSUpdateDynamicServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any Scratchpad edit still inside its autosave debounce — quitting
        // mid-sentence shouldn't lose the last few keystrokes.
        scratchpad?.flush()
        // Drop the LLM socket and unlink its file, so Meetings sees "no socket"
        // rather than connecting to a dead endpoint.
        LocalLLMServer.shared.stop()
    }

    /// The already-running Dictator instance, if any, excluding this process.
    /// Matches on bundle identifier so it catches a copy launched from a
    /// different path (the installed ~/Applications build vs a DerivedData
    /// ⌘R build) — Launch Services only dedupes by path, so those otherwise
    /// run side by side.
    private static func alreadyRunningInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let myPID = NSRunningApplication.current.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID }
    }
}
