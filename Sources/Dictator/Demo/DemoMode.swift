import AppKit
import Foundation
import Observation

/// Session-only "Demo mode": while it's on, every surface that would show the
/// user's own content — dictation history, assistant conversations, assistant
/// memory, the dictionary, the Scratchpad — shows `DemoFixtures` instead, so a
/// screen recording or screenshot can't leak anything real.
///
/// Three properties make it safe to leave in a shipping build:
///
/// - **Session-only.** `isOn` is in-memory and never persisted (deliberately
///   *not* a `DictatorSettings` field). Quitting Dictator turns it off.
/// - **Read-side only.** Nothing here writes to `history.json`,
///   `chats.json`, `assistant-memory.md`, `vocabulary.json` or
///   `scratchpad.md`. Turning it on and off again leaves every store byte for
///   byte as it was. Views call an accessor (`history(real:)`,
///   `thread(id:real:)`, …) that hands back the real value when it's off.
/// - **Live work still shows.** A dictation or assistant turn made *during* a
///   demo goes to the real stores as normal, and the accessors merge anything
///   created since `switchedOnAt` in on top of the fixtures — so "look, it's in
///   History now" works on camera.
///
/// Edits made to the *fixtures* while demoing (deleting a demo history row,
/// adding a dictionary rule, typing in the Scratchpad) land in the overlays
/// below and are thrown away when demo mode goes off.
@MainActor
@Observable
final class DemoMode {
    static let shared = DemoMode()

    private(set) var isOn = false

    /// When the switch was flipped on. Real records newer than this are shown
    /// alongside the fixtures; older real content stays hidden.
    private(set) var switchedOnAt: Date?

    // Overlays. Rebuilt on every switch-on so relative timestamps stay fresh,
    // and cleared on switch-off so a second demo starts from a clean set.
    private var historyOverlay: [DictationRecord] = []
    private var assistantThreadOverlay: [ChatThread] = []
    private var memoryOverlay: [String] = []
    private var vocabularyOverlay: [VocabularyEntry] = []

    /// Memory lines that already existed in `assistant-memory.md` when demo
    /// mode was switched on — the ones the user must NOT see. Anything in the
    /// real file that isn't in this set was remembered during the demo, so it
    /// is shown.
    private var knownMemoryLines: Set<String> = []

    private init() {}

    // MARK: - Switching

    func toggle() { setOn(!isOn) }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        if on {
            let now = Date()
            switchedOnAt = now
            historyOverlay = DemoFixtures.historyRecords(now: now)
            assistantThreadOverlay = DemoFixtures.assistantThreads(now: now)
            memoryOverlay = DemoFixtures.memoryLines
            vocabularyOverlay = DemoFixtures.vocabulary()
            knownMemoryLines = Set(AssistantMemory.shared.entries)
        } else {
            switchedOnAt = nil
            historyOverlay = []
            assistantThreadOverlay = []
            memoryOverlay = []
            vocabularyOverlay = []
            knownMemoryLines = []
        }
        isOn = on
        // The Scratchpad is the one store the user can type into, so it can't
        // be a pure read-side overlay — the controller re-points the note at a
        // throwaway folder instead. See `ScratchpadController.applyDemoMode`.
        AppState.shared.scratchpadController?.applyDemoMode(on)
        NSLog("[Dictator] Demo mode \(on ? "on" : "off")")
    }

    // MARK: - Dictation history

    /// Fixture records, plus any real dictation made since the switch went on.
    /// Both sides are newest-first and the fixtures are all in the past, so
    /// concatenating keeps the ordering the History pane expects.
    func history(real: [DictationRecord]) -> [DictationRecord] {
        guard isOn, let since = switchedOnAt else { return real }
        return real.filter { $0.timestamp >= since } + historyOverlay
    }

    /// True when the surfaced list is empty — the toolbar's Clear button and
    /// the menu bar's "Recent" section use this.
    func historyIsEmpty(real: [DictationRecord]) -> Bool {
        history(real: real).isEmpty
    }

    /// Deleting a fixture row drops it from the overlay; deleting a real row
    /// (one the user made during the demo) does the real thing.
    func removeHistory(id: UUID, real: () -> Void) {
        if isOn, historyOverlay.contains(where: { $0.id == id }) {
            historyOverlay.removeAll { $0.id == id }
            return
        }
        real()
    }

    /// "Clear all" while demoing clears only the fixtures — the real history
    /// file is never touched by anything demo mode does.
    func clearHistory(real: () -> Void) {
        if isOn {
            historyOverlay = []
            return
        }
        real()
    }

    // MARK: - Assistant threads

    /// Resolve by id for the assistant result window, which is handed an id
    /// rather than a list. Falls back to the real thread so a turn taken
    /// during the demo still opens.
    ///
    /// There's no list-level overlay any more: the recent-conversations list
    /// was removed from the menu bar when Assistant Mode and chat merged into
    /// one store, and the chat sidebar shows the real threads. A demo that
    /// needs fictional threads in the sidebar would have to seed the store,
    /// the way `ScreenshotRunner` does.
    func thread(id: UUID, real: ChatThread?) -> ChatThread? {
        if isOn, let fixture = assistantThreadOverlay.first(where: { $0.id == id }) { return fixture }
        return real
    }

    // MARK: - Assistant memory

    /// Fixture facts, plus anything the assistant was told to remember during
    /// the demo (which really was written to `assistant-memory.md`).
    func memoryLines(real: [String]) -> [String] {
        guard isOn else { return real }
        return memoryOverlay + real.filter { !knownMemoryLines.contains($0) }
    }

    /// "Open file" — while demoing, opens a throwaway copy holding the fixture
    /// facts in the real file's format, so clicking it on camera shows nothing
    /// real and edits nothing.
    func openMemoryFile() {
        guard isOn else {
            AssistantMemory.shared.openInEditor()
            return
        }
        let url = Self.demoDirectory(named: "Memory")
            .appendingPathComponent(AssistantMemory.filename)
        let today = Self.dayString(Date())
        let body = memoryLines(real: AssistantMemory.shared.entries)
            .map { "- \(today): \($0)" }
            .joined(separator: "\n")
        try? ("<!-- Dictator \u{2014} things the assistant remembers about you. -->\n\n"
              + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    func forgetAllMemory() {
        if isOn {
            memoryOverlay = []
            knownMemoryLines = Set(AssistantMemory.shared.entries)
            return
        }
        AssistantMemory.shared.forgetAll()
    }

    // MARK: - Dictionary

    /// The rules the Dictionary pane shows: fixtures only while demoing (plus
    /// anything learned during the demo, adopted explicitly by
    /// `noteVocabularyAdded` — never by mutating state from inside a view read).
    func vocabulary(real: [VocabularyEntry]) -> [VocabularyEntry] {
        isOn ? vocabularyOverlay : real
    }

    /// Write-back for the Dictionary pane's binding. While demoing, every edit
    /// — typing in a row, ticking a toggle, deleting a rule — stays in the
    /// overlay, so `vocabulary.json` is untouched for the whole session.
    func setVocabulary(_ newValue: [VocabularyEntry], real apply: ([VocabularyEntry]) -> Void) {
        if isOn {
            vocabularyOverlay = newValue
            return
        }
        apply(newValue)
    }

    /// The toolbar's "+" while demoing: a blank row in the overlay rather than
    /// in the user's dictionary file.
    func insertVocabularyEntry(_ entry: VocabularyEntry, real: () -> Void) {
        if isOn {
            vocabularyOverlay.insert(entry, at: 0)
            return
        }
        real()
    }

    /// Called when a word really was added to the user's dictionary during a
    /// demo (the "Learn Word in Dictator…" service). Mirrors it into the
    /// overlay so the demo Dictionary shows it too — the real entry is already
    /// on disk either way.
    func noteVocabularyAdded(_ entry: VocabularyEntry) {
        guard isOn, !vocabularyOverlay.contains(where: { $0.id == entry.id }) else { return }
        vocabularyOverlay.insert(entry, at: 0)
    }

    // MARK: - Scratchpad

    /// Directory the Scratchpad is re-pointed at while demo mode is on — a
    /// throwaway under the process's temp dir, seeded with the fixture note.
    /// Nothing typed while demoing can reach the real `scratchpad.md`.
    static func scratchpadDirectory() -> URL {
        demoDirectory(named: "Scratchpad")
    }

    static let scratchpadNote = DemoFixtures.scratchpadNote

    /// `yyyy-MM-dd`, the date prefix `assistant-memory.md` puts on each line.
    /// Built per call — this runs once, when the user clicks "Open file".
    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func demoDirectory(named name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictatorDemo", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - URL scheme

    /// Handles `dictator://demo`. `?on=1` (or `true`/`yes`) switches it on,
    /// `?on=0` (`false`/`no`) off, and no parameter at all toggles — so a
    /// recording script can do either.
    static func handleURL(_ url: URL) {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "on" })?
            .value?.trimmingCharacters(in: .whitespaces).lowercased()
        switch raw {
        case nil, "":                     shared.toggle()
        case "1", "true", "yes", "on":    shared.setOn(true)
        case "0", "false", "no", "off":   shared.setOn(false)
        default:
            NSLog("[Dictator] dictator://demo: unrecognised on=\(raw ?? "") — toggling")
            shared.toggle()
        }
    }
}
