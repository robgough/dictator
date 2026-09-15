import AppKit
import SwiftUI

/// One-slot registry a Settings pane hands its `ScrollViewProxy` to, so the
/// screenshot runner can scroll a named section into frame once layout has
/// settled. Inert in a normal launch: `register` no-ops unless screenshot mode
/// is on, and nothing but `ScreenshotRunner` ever calls `scroll(to:)`.
@MainActor
enum ScreenshotScroll {
    private(set) static var proxy: ScrollViewProxy?

    static func register(_ proxy: ScrollViewProxy) {
        guard ScreenshotMode.isActive else { return }
        self.proxy = proxy
    }

    static func scroll(to id: String, anchor: UnitPoint = .top) {
        proxy?.scrollTo(id, anchor: anchor)
    }
}

/// Developer-only screenshot mode for the dictation app. See `ScreenshotMode`
/// (DictatorCore) for the environment contract, and `scripts/mac-screenshots.sh`
/// for the driver. Entered from `AppDelegate.applicationDidFinishLaunching`
/// *before* the single-instance guard and before `AppState.bootstrap()`, so the
/// capture process registers no hotkeys, starts no LLM socket, checks no
/// permissions, loads no models and never disturbs the user's running copy.
@MainActor
enum ScreenshotRunner {

    static func run() {
        ScreenshotWindowCapture.startWatchdog(seconds: 20)
        ScreenshotWindowCapture.forceLightAppearance()
        NSApp.setActivationPolicy(.regular)
        seedSettings()
        // Hop off `applicationDidFinishLaunching` before doing any of the
        // window work: AppKit only finishes activating the app once the launch
        // callback has returned, and an inactive app draws inactive chrome
        // (grey traffic lights, untinted switches) — not what a marketing
        // screenshot wants.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { perform() }
    }

    private static func perform() {
        NSApp.activate(ignoringOtherApps: true)
        ScreenshotWindowCapture.settle(seconds: 0.4)

        switch ScreenshotMode.shot {
        case "modes":           captureSettings(tab: .modes)
        case "hud-styles":      captureHUDStyles()
        case "assistant-draft": captureAssistantDraft()
        case "demo-history":    captureDemoHistory()
        default:
            NSLog("[Screenshot] Unknown shot '\(ScreenshotMode.shot ?? "")' for Dictator")
            exit(64)
        }
    }

    // MARK: - Fixture data (fictional; never the user's own)

    /// The fixtures live in `DemoFixtures`, shared with the user-facing Demo
    /// mode — one cast, one set of facts, so a marketing shot and a recorded
    /// demo can never drift apart.
    private static func seedSettings() {
        AppState.shared.settings = DemoFixtures.settings()
        AppState.shared.pipeline.settingsChanged(AppState.shared.settings)
    }

    /// A one-turn assistant thread whose reply is a short drafted email.
    private static func seedConversation() -> UUID {
        let thread = ChatThread.assistant(turns: [DemoFixtures.draftReplyTurn()])
        ChatStore.shared.upsert(thread)
        return thread.id
    }

    /// The dictation-history fixtures, written into this capture process's
    /// throwaway store (`DICTATOR_SCREENSHOT_DATA` rebases every path), oldest
    /// first so the store's newest-first ordering comes out right.
    private static func seedHistory() {
        for record in DemoFixtures.historyRecords().reversed() {
            DictationHistory.shared.append(record)
        }
    }

    // MARK: - Shots

    private static func captureSettings(tab: DictationSubPane) {
        let controller = SettingsWindowController.shared
        controller.model.section = .dictation
        controller.model.dictationTab = tab
        controller.show()
        ScreenshotWindowCapture.settle(seconds: 1.2)
        guard let window = settingsWindow() else { fail("no settings window") }
        ScreenshotWindowCapture.place(window, size: NSSize(width: 940, height: 600))
        ScreenshotWindowCapture.settle(seconds: 1.0)
        write(window)
    }

    /// Settings -> Dictation -> History with the demo fixtures in it. Not used
    /// on the marketing site — it exists so the fixtures that back Demo mode
    /// can be eyeballed the same way every other shot is.
    private static func captureDemoHistory() {
        seedHistory()
        captureSettings(tab: .history)
    }

    private static func captureHUDStyles() {
        let controller = SettingsWindowController.shared
        controller.model.section = .general
        controller.show()
        ScreenshotWindowCapture.settle(seconds: 1.2)
        guard let window = settingsWindow() else { fail("no settings window") }
        // Tall enough that the pane runs from Permissions down to the HUD
        // gallery without scrolling: scrolled content slides under the
        // transparent toolbar and shows through as a ghost line in a capture,
        // and the Sounds cards below build their waveforms asynchronously.
        ScreenshotWindowCapture.place(window, size: NSSize(width: 940, height: 870))
        ScreenshotWindowCapture.settle(seconds: 1.5)
        write(window)
    }

    private static func captureAssistantDraft() {
        let id = seedConversation()
        let controller = AssistantResultController()
        controller.showThread(id: id, surface: true)
        ScreenshotWindowCapture.settle(seconds: 1.0)
        guard let window = ScreenshotWindowCapture.window(where: { $0.title == "Assistant" }) else {
            fail("no assistant window")
        }
        ScreenshotWindowCapture.place(window, size: NSSize(width: 780, height: 430))
        ScreenshotWindowCapture.settle(seconds: 1.0)
        write(window)
    }

    // MARK: - Plumbing

    /// The Settings window is AppKit-owned and its `NSWindow` is private to the
    /// controller, so find it by its split-view content.
    private static func settingsWindow() -> NSWindow? {
        ScreenshotWindowCapture.window { $0.contentViewController is NSSplitViewController }
    }

    private static func write(_ window: NSWindow) -> Never {
        ScreenshotWindowCapture.activate(window)
        ScreenshotWindowCapture.settle(seconds: 0.5)
        guard let path = ScreenshotMode.outputPath else { fail("DICTATOR_SCREENSHOT_OUT unset") }
        let size = ScreenshotWindowCapture.capture(window, to: path)
        ScreenshotWindowCapture.finish(size, path: path)
    }

    private static func fail(_ reason: String) -> Never {
        NSLog("[Screenshot] \(reason)")
        exit(1)
    }
}
