import AppKit
import Foundation
import Observation

/// The journal, as the window sees it: which days have something in them, what
/// today's page says, and the four things you can do to it — add, edit, delete,
/// undo.
///
/// **Why a store and not just `JournalArchive`.** That type answers a question
/// for a language model: it walks, searches and renders prose. A window needs
/// the opposite — a stable index it can draw a calendar from, entries with
/// identity, and writes that keep both in step. So the archive stays as it is
/// (it is measured, and `scratch/journal-bench` runs the shipping copy), and
/// this sits on top.
///
/// **What it costs.** The day index is one directory walk and a scan of each
/// *filename* — no file is opened — which is what makes a calendar over a
/// five-year archive free. Opening a day parses one or two files. Both happen
/// off the main actor.
///
/// **Refresh, not watching.** These are plain files in somebody's folder and
/// another editor may well be open on the same day. Rather than a file
/// descriptor per file (which an atomic save invalidates the moment Obsidian
/// writes), the window re-reads when it becomes key, on a slow timer while it
/// is, and immediately after any write of its own — including the hotkey's,
/// via `noteWrite`. Switching apps is exactly the gesture that precedes
/// wanting to see someone else's change, so focus is the signal that matters.
@MainActor
@Observable
final class JournalStore {
    static let shared = JournalStore()

    /// One file's worth of a day. A date can span more than one file — the
    /// author's own archive does, because the path template changed under it —
    /// and the window shows them as one day made of two parts rather than two
    /// days or one merged blur.
    struct FileGroup: Identifiable, Sendable {
        let url: URL
        let entries: [JournalArchive.Entry]
        /// The file verbatim, set only when entries can't be told apart
        /// because the user's entry template doesn't write headings.
        let wholeFile: String?

        var id: String { url.path }
    }

    /// Something to say, and whether it went wrong.
    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    /// The last change, and what to call it.
    struct PendingUndo {
        let undo: JournalEditor.Undo
        /// "Entry deleted" / "Entry edited" — the label on the bar.
        let what: String
    }

    // MARK: - State

    private(set) var days: [JournalArchive.Day] = []
    /// ISO `yyyy-MM-dd` of the day on screen.
    private(set) var selectedKey: String?
    private(set) var groups: [FileGroup] = []
    private(set) var isLoading = false
    private(set) var notice: Notice?
    private(set) var pendingUndo: PendingUndo?
    /// Set when the path template can't produce a date per file, so there are
    /// no days to show. The window explains rather than showing an empty
    /// calendar and letting the user wonder where their journal went.
    private(set) var daysUnavailable = false

    /// Days that have something in them, for the calendar's dots.
    private(set) var populatedKeys: Set<String> = []

    /// Guards against a slow load of a day the user has already navigated away
    /// from landing on top of a newer one.
    private var loadToken = 0

    /// True while the window is open. Everything here is lazy and free until
    /// then — in particular the hotkey's `noteWrite` does no directory walk for
    /// a user who has never opened the window.
    private var isObserving = false

    /// When each file of the day on screen was last modified, so the timer can
    /// tell "nothing has happened" from "Obsidian saved" without re-parsing.
    private var loadedStamps: [URL: Date] = [:]

    private var settings: DictatorSettings { AppState.shared.settings }

    // MARK: - Dates

    /// One formatter, and a fixed locale — these keys are filenames, not
    /// display text, and they're compared as strings (see
    /// `JournalArchive.dateKey`).
    static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(for date: Date) -> String { keyFormatter.string(from: date) }
    static func date(for key: String) -> Date? { keyFormatter.date(from: key) }

    var todayKey: String { Self.key(for: Date()) }
    var isShowingToday: Bool { selectedKey == todayKey }

    /// Whether entries in this journal can be told apart at all. False when the
    /// user's entry template doesn't start with a heading, in which case a day
    /// is shown whole and can be read but not edited entry by entry.
    var entriesAreSeparable: Bool {
        JournalTemplateShape.entriesAreParseable(entryTemplate: settings.journalEntryTemplate)
    }

    // MARK: - Loading

    /// Rebuild the day index, then reload whatever day is on screen.
    func refresh() {
        guard let root = JournalWriter.root(pathTemplate: settings.journalPathTemplate) else {
            // No folder yet — nothing has ever been written. Not an error.
            days = []
            populatedKeys = []
            groups = []
            daysUnavailable = !JournalTemplateShape.daysAreFindable(
                pathTemplate: settings.journalPathTemplate)
            if selectedKey == nil { selectedKey = todayKey }
            return
        }
        daysUnavailable = !JournalTemplateShape.daysAreFindable(
            pathTemplate: settings.journalPathTemplate)
        Task {
            let found = await Task.detached { JournalArchive(root: root).days() }.value
            self.days = found
            self.populatedKeys = Set(found.map(\.key))
            if self.selectedKey == nil {
                // Today if there's anything in it, otherwise the most recent
                // day that has something — opening on a blank page when you
                // wrote three things yesterday is the wrong first impression.
                self.selectedKey = self.populatedKeys.contains(self.todayKey)
                    ? self.todayKey
                    : (found.first?.key ?? self.todayKey)
            }
            self.loadSelectedDay()
        }
    }

    func select(key: String) {
        guard key != selectedKey else { return }
        selectedKey = key
        pendingUndo = nil
        notice = nil
        loadSelectedDay()
    }

    func selectToday() { select(key: todayKey) }

    /// Read the selected day's file(s) and parse them.
    func loadSelectedDay() {
        guard let key = selectedKey else { groups = []; return }
        let files = days.first(where: { $0.key == key })?.files ?? []
        guard !files.isEmpty else { groups = []; isLoading = false; return }
        let separable = entriesAreSeparable
        loadToken += 1
        let token = loadToken
        isLoading = true
        Task {
            let loaded = await Task.detached { () -> [FileGroup] in
                files.map { url in
                    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    return FileGroup(
                        url: url,
                        entries: separable ? JournalArchive.parseEntries(in: contents, url: url) : [],
                        wholeFile: separable ? nil : contents)
                }
            }.value
            // A day the user has already navigated away from must not land on
            // top of the one they're looking at now.
            guard token == self.loadToken else { return }
            self.groups = loaded
            self.loadedStamps = Dictionary(
                uniqueKeysWithValues: loaded.map { group in
                    (group.url,
                     (try? group.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast)
                })
            self.isLoading = false
        }
    }

    /// Which day a journal file belongs to, the same way the walk decides it.
    ///
    /// Root-aware, because the date may live in the folders rather than the
    /// filename. Falls back to the filename alone when there's no root yet —
    /// which is the case on the very first entry, before the folder exists.
    func dayKey(for url: URL) -> String? {
        guard let root = JournalWriter.root(pathTemplate: settings.journalPathTemplate) else {
            return JournalArchive.dateKey(from: url)
        }
        return JournalArchive.dateKey(for: url, root: root)
    }

    func beginObserving() { isObserving = true }

    func endObserving() {
        isObserving = false
        loadedStamps = [:]
    }

    /// The window's slow tick. Re-reads only when a file of the day on screen
    /// has actually changed — the common case is that nothing has, and parsing
    /// a day every thirty seconds to discover that would be work for nothing.
    func refreshIfUnchanged() {
        guard isObserving, let key = selectedKey else { return }
        let files = days.first(where: { $0.key == key })?.files ?? []
        let known = loadedStamps
        Task {
            let changed = await Task.detached { () -> Bool in
                // A file that has appeared, vanished or moved counts too.
                if files.count != known.count { return true }
                for url in files {
                    let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    guard let stamp, let seen = known[url], stamp == seen else { return true }
                }
                return false
            }.value
            guard changed else { return }
            self.refresh()
        }
    }

    /// An entry was written outside this window — the hotkey, most likely.
    /// Show it: jump to its day and re-read.
    ///
    /// Does nothing when the window isn't open, so the hotkey costs exactly
    /// what it always did for everyone who never opens it.
    func noteWrite(url: URL) {
        guard isObserving else { return }
        let key = dayKey(for: url) ?? todayKey
        pendingUndo = nil
        if selectedKey != key {
            selectedKey = key
            notice = nil
        }
        refresh()
    }

    // MARK: - Adding

    /// Add an entry to today.
    ///
    /// Today, always. `JournalWriter` resolves both the file and the `## HH:MM`
    /// heading from the date it's handed, so filing into a past day would mean
    /// either inventing a timestamp or writing one that sorts after a day that
    /// finished hours ago. The window offers to jump to today instead.
    func add(text: String, images: [URL]) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || !images.isEmpty else { return }
        let now = Date()
        let header = settings.journalHeaderTemplate
        let entryTemplate = settings.journalEntryTemplate
        do {
            let url = try JournalWriter.resolvedURL(pathTemplate: settings.journalPathTemplate, date: now)
            let body = try await Task.detached { () -> String in
                // The photos land beside the note first, so the entry can name
                // them. A copy that fails takes the whole write with it rather
                // than filing an entry that points at nothing.
                let lines = try images.map {
                    try JournalAttachments.attach($0, besideNote: url, date: now)
                }
                return JournalMarkdown.assemble(
                    prose: words,
                    images: lines.compactMap { JournalMarkdown.imageRef(in: $0) })
            }.value
            _ = try await Task.detached {
                try JournalWriter.append(text: body,
                                         to: url,
                                         headerTemplate: header,
                                         entryTemplate: entryTemplate,
                                         appName: nil,
                                         date: now)
            }.value
            pendingUndo = nil
            notice = nil
            selectedKey = Self.key(for: now)
            refresh()
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: - Changing what's there

    /// Rewrite one entry's words, keeping the photos it already had.
    func edit(_ entry: JournalArchive.Entry,
              prose: String,
              keeping images: [JournalMarkdown.ImageRef],
              adding newImages: [URL]) async {
        let url = entry.fileURL
        let expecting = entry.text
        let ordinal = entry.ordinal
        let now = Date()
        do {
            let body = try await Task.detached { () -> String in
                let added = try newImages.map {
                    try JournalAttachments.attach($0, besideNote: url, date: now)
                }
                return JournalMarkdown.assemble(
                    prose: prose,
                    images: images + added.compactMap { JournalMarkdown.imageRef(in: $0) })
            }.value
            let undo = try await Task.detached {
                try JournalEditor.replace(ordinal: ordinal, in: url, expecting: expecting, with: body)
            }.value
            pendingUndo = PendingUndo(undo: undo, what: "Entry edited")
            notice = nil
            refresh()
        } catch {
            handle(error)
        }
    }

    /// Remove an entry, heading and all.
    ///
    /// Any photos it referenced stay on disk. They're the user's files, they
    /// may well be linked from somewhere else, and deleting somebody's
    /// photographs as a side effect of tidying a sentence is not a thing to do
    /// quietly.
    func delete(_ entry: JournalArchive.Entry) async {
        let url = entry.fileURL
        let expecting = entry.text
        let ordinal = entry.ordinal
        do {
            let undo = try await Task.detached {
                try JournalEditor.delete(ordinal: ordinal, in: url, expecting: expecting)
            }.value
            pendingUndo = PendingUndo(undo: undo, what: "Entry deleted")
            notice = nil
            refresh()
        } catch {
            handle(error)
        }
    }

    /// Put the last change back.
    func undoLast() async {
        guard let pending = pendingUndo else { return }
        do {
            try await Task.detached { try JournalEditor.undo(pending.undo) }.value
            pendingUndo = nil
            notice = nil
            refresh()
        } catch {
            // The words are still in the undo, so say so rather than just
            // reporting a failure — this is the last copy of them.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pending.undo.text, forType: .string)
            pendingUndo = nil
            notice = Notice(
                text: "Couldn't undo — the file has changed since. The entry's text is on your clipboard.",
                isError: true)
            refresh()
        }
    }

    /// A failed write always re-reads: whatever refused us knows something we
    /// don't, and the page should show what's actually there.
    private func handle(_ error: Error) {
        notice = Notice(text: error.localizedDescription, isError: true)
        refresh()
    }

    func dismissNotice() { notice = nil }
    func dismissUndo() { pendingUndo = nil }
}
