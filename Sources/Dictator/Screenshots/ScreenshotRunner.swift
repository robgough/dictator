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
        case "journal":         captureJournal()
        case "chat":            captureChat()
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

    /// The journal fixtures, written through `JournalWriter` into this capture
    /// process's throwaway synced folder so the window reads them the way it
    /// reads a real journal.
    private static func seedJournal() {
        AppState.shared.settings.journalPathTemplate = DemoFixtures.journalPathTemplate
        let settings = AppState.shared.settings
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        for entry in DemoFixtures.journalEntries {
            guard let day = calendar.date(byAdding: .day, value: -entry.daysAgo, to: today),
                  let date = calendar.date(
                      bySettingHour: entry.hour, minute: entry.minute, second: 0, of: day)
            else { continue }
            do {
                try JournalWriter.append(
                    text: entry.text,
                    pathTemplate: settings.journalPathTemplate,
                    headerTemplate: settings.journalHeaderTemplate,
                    entryTemplate: settings.journalEntryTemplate,
                    appName: nil,
                    date: date)
            } catch {
                fail("journal seed: \(error.localizedDescription)")
            }
        }
    }

    /// One chat: the journal read as a tool, a note saved from it, and the
    /// reply. The note is written to disk for real, because the file card
    /// re-reads it on every render.
    private static func seedChat() -> UUID {
        let modelID = "mlx-community/Qwen3.5-4B-4bit"
        AppState.shared.settings.llmEngine = .mlx
        AppState.shared.settings.llmModelID = modelID

        let start = Date().addingTimeInterval(-90)
        var thread = ChatThread(createdAt: start, modelID: modelID)
        thread.append(ChatMessage(kind: .user, text: DemoFixtures.chatUserMessage, timestamp: start))

        var search = ChatMessage(
            kind: .tool, text: "Read the journal", timestamp: start.addingTimeInterval(4),
            toolCall: ChatWireToolCall(
                name: "search_journal",
                arguments: .object(["query": .string("Northwind"), "days_back": .int(14)])))
        search.toolResult = DemoFixtures.chatJournalResult
        thread.append(search)

        guard let folder = try? ChatFiles.folder(for: thread) else { fail("no chat folder") }
        thread.filesFolderName = folder.folderName
        try? FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let noteURL = folder.url.appendingPathComponent(DemoFixtures.chatNoteName)
        let noteData = Data(DemoFixtures.chatNote.utf8)
        do { try noteData.write(to: noteURL) } catch { fail("chat note: \(error.localizedDescription)") }

        var save = ChatMessage(
            kind: .tool, text: "Save a file", timestamp: start.addingTimeInterval(9),
            toolCall: ChatWireToolCall(
                name: "create_file",
                arguments: .object([
                    "name": .string(DemoFixtures.chatNoteName),
                    "contents": .string(DemoFixtures.chatNote),
                ])),
            producedFile: ProducedFile(
                name: DemoFixtures.chatNoteName, path: noteURL.path, byteCount: noteData.count))
        save.toolResult = "Saved \(DemoFixtures.chatNoteName)."
        thread.append(save)

        thread.append(ChatMessage(
            kind: .assistant, text: DemoFixtures.chatReply, timestamp: start.addingTimeInterval(14)))
        ChatStore.shared.upsert(thread)
        return thread.id
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
        guard let window = ScreenshotWindowCapture.window(where: { $0.title == "Dictator Assistant" }) else {
            fail("no assistant window")
        }
        ScreenshotWindowCapture.place(window, size: NSSize(width: 780, height: 430))
        ScreenshotWindowCapture.settle(seconds: 1.0)
        write(window)
    }

    private static func captureJournal() {
        seedJournal()
        JournalWindowController.shared.show()
        // The journal loads its days in a `Task`, and main-actor tasks can't
        // run while we're still inside the main-queue block `run()` scheduled —
        // `settle()` spins the run loop, not the main queue. Return, and finish
        // from a timer, whose callback leaves the main queue free to drain.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated { finishJournal() }
        }
    }

    private static func finishJournal() {
        ScreenshotWindowCapture.settle(seconds: 1.0)
        guard !JournalStore.shared.populatedKeys.isEmpty else { fail("journal loaded no days") }
        guard let window = ScreenshotWindowCapture.window(where: { $0.title == "Dictator Journal" }) else {
            fail("no journal window")
        }
        ScreenshotWindowCapture.place(window, size: NSSize(width: 940, height: 640))
        ScreenshotWindowCapture.settle(seconds: 1.0)
        write(window)
    }

    private static func captureChat() {
        let id = seedChat()
        let controller = ChatWindowController.shared
        controller.show()
        controller.select(threadID: id)
        ScreenshotWindowCapture.settle(seconds: 1.5)
        guard let window = ScreenshotWindowCapture.window(where: { $0.title == "Dictator Chat" }) else {
            fail("no chat window")
        }
        ScreenshotWindowCapture.place(window, size: NSSize(width: 940, height: 700))
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
