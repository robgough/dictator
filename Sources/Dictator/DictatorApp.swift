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
        // `isInserted` is false only in screenshot mode, so a capture run
        // doesn't drop a second Dictator glyph in the user's menu bar.
        MenuBarExtra(isInserted: .constant(!ScreenshotMode.isActive)) {
            MenuBarContent()
                .environment(appState)
                .onOpenURL { url in handleURL(url) }
        } label: {
            Image(systemName: appState.pipeline.state.iconName)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
        // The app's real menu bar. Invisible while Dictator is an `.accessory`
        // — which is nearly always — but the moment a window opens we flip to
        // `.regular` and this is what people get. Without it, ⌘, did nothing in
        // the Chat window, which is the one place in the app where someone is
        // sitting in front of a window and reaching for it.
        //
        // `.appSettings` is replaced rather than added to, because there is no
        // SwiftUI `Settings` scene to point at: the window is AppKit-owned (see
        // `SettingsWindowController`).
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.setActivationPolicy(.regular)
                    SettingsWindowController.shared.show()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("New Chat") {
                    ChatWindowController.shared.show()
                    ChatWindowController.shared.newThread()
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Chat…") {
                    ChatWindowController.shared.show()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        // Settings is NOT a SwiftUI `Settings` scene: the window is owned by
        // `SettingsWindowController` (SettingsShell.swift), which builds real
        // AppKit chrome — NSSplitViewController sidebar + unified NSToolbar —
        // that the scene version could only fake, with dead controls in the
        // titlebar strip to show for it.

    }

    /// Routes incoming `dictator://…` URLs. Three hosts handled today:
    /// `settings` opens the Settings window, `onboarding` re-shows the wizard,
    /// and `demo?on=1` / `demo?on=0` drives Demo mode (no parameter toggles) so
    /// a recording script can switch it without touching Settings. Anything
    /// else is logged and ignored. (`dictator://meetings` is gone — meetings
    /// live in Dictator Meetings, which answers `dictator-meetings://`.)
    private func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "dictator" else { return }
        switch url.host?.lowercased() {
        case "settings":
            SettingsWindowController.shared.show()
        case "demo":
            DemoMode.handleURL(url)
        case "onboarding", "setup", "wizard":
            NSApp.activate(ignoringOtherApps: true)
            appState.showOnboarding()
        default:
            NSLog("[Dictator] Ignoring unknown URL: \(url.absoluteString)")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hud: DictationHUDController?
    private var scratchpad: ScratchpadController?
    // Held by the delegate so the strong reference outlives every
    // services-menu invocation. `NSApp.servicesProvider` is `weak`.
    private let learnWordProvider = LearnWordProvider()

    /// Routes `dictator://…` URLs. Five hosts handled:
    /// `dictator://settings` opens the Settings window; `dictator://chat` and
    /// `dictator://journal` open those windows; `dictator://onboarding`
    /// (or `setup` / `wizard`) re-shows the first-run wizard; and
    /// `dictator://demo?on=1` / `?on=0` switches Demo mode on or off (with no
    /// `on` parameter it toggles). Useful both as a deep-link target for
    /// support docs and for automation.
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
            case "chat":
                Task { @MainActor in ChatWindowController.shared.show() }
            case "journal":
                Task { @MainActor in JournalWindowController.shared.show() }
            case "demo":
                DemoMode.handleURL(url)
            case "onboarding", "setup", "wizard":
                NSApp.activate(ignoringOtherApps: true)
                AppState.shared.showOnboarding()
            default:
                NSLog("[Dictator] Ignoring unknown URL: \(url.absoluteString)")
            }
        }
    }

    /// Clicking Dictator in the Dock (or double-clicking the app when it's
    /// already running) opens the Chat window.
    ///
    /// Before this, an accessory app with no windows answered a reopen by
    /// doing nothing at all — the app was already running, so Launch Services
    /// had nothing to do, and the user got no feedback whatsoever. Chat is the
    /// natural thing to show: it's the only window in the app someone would
    /// want to sit in front of.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        // Don't steal focus from a window the user already has open (Settings,
        // an assistant result) — reopen fires for those too.
        guard !hasVisibleWindows else { return true }
        Task { @MainActor in ChatWindowController.shared.show() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer-only screenshot mode: seed fixtures, render one window to
        // a PNG, exit. Deliberately ahead of the single-instance guard — the
        // capture runs alongside the user's installed copy and must not quit,
        // relaunch or disturb it — and it never reaches `bootstrap()`, so no
        // hotkeys, no LLM socket, no models, no permission checks.
        if ScreenshotMode.isActive {
            ScreenshotRunner.run()
            return
        }

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
            // doesn't race with hiding the dock icon — and then only drop the
            // dock icon if nothing else is still on screen. With Chat as a
            // second titled window, closing one while the other is open used
            // to take the app back to accessory with a visible window left
            // behind, which loses its dock icon and its place in ⌘-Tab.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let stillOpen = NSApp.windows.contains { other in
                    other !== win && other.isVisible
                        && !other.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !stillOpen else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
        // Start Sparkle's background update schedule (first touch creates the
        // controller; `UpdaterGate` decides whether it actually starts).
        _ = SparkleUpdater.controller

        let state = AppState.shared
        // Settings is an AppKit-owned window now; the captured-action
        // indirection remains because the menu bar and scripts call
        // `state.openSettingsAction` without importing the controller.
        state.openSettingsAction = { SettingsWindowController.shared.show() }
        hud = DictationHUDController(state: state)
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
        // Drop the LLM socket and unlink its file, so Dictator Meetings sees
        // "no socket" rather than connecting to a dead endpoint.
        LocalLLMServer.shared.stop()
        // Flush any chat still inside its save debounce.
        ChatStore.shared.flush()
        // Kill every MCP subprocess we spawned. Synchronous on purpose: this
        // method returns straight into exit(), so an async teardown would
        // never run and the user would collect an orphaned `node` per quit.
        MCPProcessReaper.terminateAll()
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
