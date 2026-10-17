import Foundation
import Observation

/// The iPhone's view of the journal: the same Markdown files the Mac writes,
/// read and appended to through the shared folder.
///
/// **Where the files are.** The Mac resolves a relative path template against
/// its synced folder; the iPhone's equivalent is the shared folder the user
/// picked in Settings (typically the same iCloud Drive › Documents › Dictator).
/// The templates themselves come from the Mac's `settings.json` in that
/// folder when it's there, so both devices file entries identically. The
/// Mac's default template is an absolute `~/Documents/Dictator/…` path; that
/// prefix is the synced folder, so it's rewritten to a relative one here. A
/// Mac template pointing anywhere else (an Obsidian vault outside the synced
/// folder) can't be reached from the phone, and the journal says so rather
/// than quietly writing somewhere the Mac never looks.
///
/// Without a shared folder the journal lives in the app's own Documents, like
/// the Scratchpad, and the tab nudges toward connecting one.
///
/// A deliberately smaller cousin of the Mac's `JournalStore`: no photos, no
/// calendar grid, the same splice-based edit/delete/undo via `JournalEditor`.
@MainActor
@Observable
final class JournalModel {
    static let shared = JournalModel()

    struct Templates: Equatable {
        var path: String
        var header: String
        var entry: String
    }

    struct FileGroup: Identifiable {
        let url: URL
        let entries: [JournalArchive.Entry]
        /// The whole file, when the entry template has no heading to split on.
        let wholeFile: String?
        var id: String { url.path }
    }

    /// A photo waiting to be written beside a note — from the camera or
    /// the photo library, so it's bytes, not a file.
    struct PendingPhoto: Identifiable, Sendable {
        let id = UUID()
        let data: Data
        let fileExtension: String
        let name: String
    }

    struct PendingUndo {
        let undo: JournalEditor.Undo
        let what: String
    }

    private(set) var days: [JournalArchive.Day] = []
    private(set) var selectedKey: String = JournalModel.key(for: Date())
    private(set) var groups: [FileGroup] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var pendingUndo: PendingUndo?
    /// Set when the Mac's journal lives outside the shared folder.
    private(set) var macJournalElsewhere: String?
    private(set) var templates = Templates(
        path: JournalModel.defaultPathTemplate,
        header: JournalWriter.defaultHeaderTemplate,
        entry: JournalWriter.defaultEntryTemplate
    )

    private var loadToken = 0

    /// Bumped by the mic bar's camera button (it lives in the tab bar, not
    /// in `JournalView`); the page watches it and opens the camera.
    private(set) var photoRequests = 0
    func requestPhoto() { photoRequests &+= 1 }

    /// Relative form of the Mac default, resolved against the shared folder.
    static let defaultPathTemplate = "Journal/{yyyy}/{MM}/{yyyy}-{MM}-{dd}.md"
    /// The Mac's synced folder in its own default template's spelling.
    private static let macSyncedPrefix = "~/Documents/Dictator/"

    // MARK: - Location

    var base: URL {
        SharedFolderBookmark.activeURL ?? SyncedStorage.defaultDirectory
    }

    var isShared: Bool { SharedFolderBookmark.activeURL != nil }

    /// Re-read the templates from the Mac's settings in the shared folder.
    func reloadTemplates() {
        macJournalElsewhere = nil
        var next = Templates(
            path: Self.defaultPathTemplate,
            header: JournalWriter.defaultHeaderTemplate,
            entry: JournalWriter.defaultEntryTemplate
        )
        if isShared, let mac = Self.readMacSettings(in: base) {
            if let header = mac["journalHeaderTemplate"] as? String { next.header = header }
            if let entry = mac["journalEntryTemplate"] as? String { next.entry = entry }
            if let path = mac["journalPathTemplate"] as? String {
                if path.hasPrefix(Self.macSyncedPrefix) {
                    next.path = String(path.dropFirst(Self.macSyncedPrefix.count))
                } else if path.hasPrefix("/") || path.hasPrefix("~") {
                    macJournalElsewhere = path
                } else {
                    next.path = path
                }
            }
        }
        templates = next
    }

    /// `settings.json` is `{schemaVersion, settings: {...}}`; see
    /// `DictatorSettings.writeEnvelope`.
    private static func readMacSettings(in folder: URL) -> [String: Any]? {
        let url = folder.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["settings"] as? [String: Any]
    }

    // MARK: - Dates

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

    var entriesAreSeparable: Bool {
        JournalTemplateShape.entriesAreParseable(entryTemplate: templates.entry)
    }

    /// The populated day before / after the one on screen, for the arrows.
    var previousKey: String? { days.map(\.key).filter { $0 < selectedKey }.max() }
    var nextKey: String? {
        let later = days.map(\.key).filter { $0 > selectedKey }.min()
        // Today is always reachable going forward, even when it's empty.
        if let later { return later }
        return selectedKey < todayKey ? todayKey : nil
    }

    // MARK: - Loading

    func refresh() {
        reloadTemplates()
        let pathTemplate = templates.path
        let root = JournalWriter.root(pathTemplate: pathTemplate, relativeTo: base)
        guard let root else {
            days = []
            groups = []
            return
        }
        let pattern = JournalPathPattern.make(pathTemplate: pathTemplate)
        Task {
            let found = await Task.detached { JournalArchive(root: root, pattern: pattern).days() }.value
            self.days = found
            self.corpus = nil
            self.loadSelectedDay()
        }
    }

    func select(key: String) {
        guard key != selectedKey else { return }
        selectedKey = key
        pendingUndo = nil
        errorMessage = nil
        loadSelectedDay()
    }

    private func loadSelectedDay() {
        let files = days.first(where: { $0.key == selectedKey })?.files ?? []
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
                        wholeFile: separable ? nil : contents
                    )
                }
            }.value
            guard token == self.loadToken else { return }
            self.groups = loaded
            self.isLoading = false
        }
    }

    // MARK: - Search

    struct SearchHit: Identifiable, Sendable {
        let dayKey: String
        let entry: JournalArchive.Entry
        var id: String { entry.id }
    }

    /// Every entry in the journal, newest day first, parsed once and kept
    /// until the next refresh so typing a query doesn't re-read every file
    /// on each keystroke.
    private var corpus: [SearchHit]?

    /// Entries containing every term of `query` (see `ChatSearch.terms`),
    /// newest first. Empty for an empty query.
    func search(_ query: String) async -> [SearchHit] {
        let terms = ChatSearch.terms(in: query)
        guard !terms.isEmpty else { return [] }
        let all: [SearchHit]
        if let corpus {
            all = corpus
        } else {
            let days = days.sorted { $0.key > $1.key }
            all = await Task.detached { () -> [SearchHit] in
                days.flatMap { day in
                    day.files.flatMap { url -> [SearchHit] in
                        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                        return JournalArchive.parseEntries(in: contents, url: url)
                            .reversed()
                            .map { SearchHit(dayKey: day.key, entry: $0) }
                    }
                }
            }.value
            corpus = all
        }
        return all.filter { ChatSearch.score(JournalMarkdown.prose(in: $0.entry.text), terms: terms) == terms.count }
    }

    // MARK: - Writing

    /// Append an entry to today — the only day `JournalWriter` can file into
    /// honestly, since it stamps the heading from the moment of writing.
    /// Photos are written beside the note first, so the entry can name them;
    /// one that fails takes the whole write with it rather than filing an
    /// entry that points at nothing.
    func add(_ text: String, photos: [PendingPhoto] = []) async throws {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty || !photos.isEmpty else { return }
        reloadTemplates()
        let now = Date()
        let header = templates.header
        let entry = templates.entry
        do {
            let url = try JournalWriter.resolvedURL(pathTemplate: templates.path, relativeTo: base, date: now)
            _ = try await Task.detached {
                let body = try Self.body(prose: words, keeping: [], adding: photos, note: url, date: now)
                return try JournalWriter.append(text: body, to: url, headerTemplate: header,
                                                entryTemplate: entry, appName: nil, date: now)
            }.value
        } catch {
            // The words would be lost otherwise: say so, and keep them.
            errorMessage = "Couldn't save the entry (\(error.localizedDescription)). It's on your clipboard."
            throw error
        }
        pendingUndo = nil
        errorMessage = nil
        selectedKey = Self.key(for: now)
        refresh()
    }

    /// Rewrite one entry's words, keeping the photos the user didn't remove
    /// and adding any new ones.
    func edit(_ entry: JournalArchive.Entry,
              prose: String,
              keeping images: [JournalMarkdown.ImageRef],
              adding photos: [PendingPhoto]) async {
        let (url, expecting, ordinal) = (entry.fileURL, entry.text, entry.ordinal)
        let now = Date()
        do {
            let undo = try await Task.detached {
                let body = try Self.body(prose: prose, keeping: images, adding: photos, note: url, date: now)
                return try JournalEditor.replace(ordinal: ordinal, in: url, expecting: expecting, with: body)
            }.value
            pendingUndo = PendingUndo(undo: undo, what: "Entry edited")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    /// The entry body: words, then photo links underneath — the same shape
    /// the Mac writes.
    private nonisolated static func body(prose: String,
                                         keeping: [JournalMarkdown.ImageRef],
                                         adding photos: [PendingPhoto],
                                         note: URL,
                                         date: Date) throws -> String {
        let added = try photos.map {
            try JournalAttachments.attach($0.data, name: $0.name, fileExtension: $0.fileExtension,
                                          besideNote: note, date: date)
        }
        return JournalMarkdown.assemble(
            prose: prose,
            images: keeping + added.compactMap { JournalMarkdown.imageRef(in: $0) })
    }

    func delete(_ entry: JournalArchive.Entry) async {
        let (url, expecting, ordinal) = (entry.fileURL, entry.text, entry.ordinal)
        do {
            let undo = try await Task.detached {
                try JournalEditor.delete(ordinal: ordinal, in: url, expecting: expecting)
            }.value
            pendingUndo = PendingUndo(undo: undo, what: "Entry deleted")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    /// Returns the entry's text if the undo couldn't be applied, so the
    /// caller can put the last copy of those words somewhere safe.
    func undoLast() async -> String? {
        guard let pending = pendingUndo else { return nil }
        pendingUndo = nil
        do {
            try await Task.detached { try JournalEditor.undo(pending.undo) }.value
            errorMessage = nil
            refresh()
            return nil
        } catch {
            errorMessage = "Couldn't undo — the file has changed since. The entry's text is on your clipboard."
            refresh()
            return pending.undo.text
        }
    }

    func dismissUndo() { pendingUndo = nil }
    func dismissError() { errorMessage = nil }
}
