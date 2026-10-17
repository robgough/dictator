import Foundation

/// The user's journal on disk, as something you can read rather than a folder
/// you have to walk.
///
/// Split out of `ChatTools` so it depends on nothing but Foundation and
/// `ChatSearch` — no settings struct, no AppKit. That makes it exercisable
/// outside the app, which matters: this code was shipped twice on the strength
/// of "it compiles" and was wrong both times. `scratch/journal-bench` runs
/// *this file* against a five-year archive.
struct JournalArchive {
    /// Directory holding the journal files, at any depth.
    let root: URL

    /// The user's path template, compiled so it can be read backwards. When it
    /// matches a file, the date is *known* rather than guessed — which is the
    /// only way a month written as "September", or a day-first date, can be
    /// read at all. Files it doesn't match fall back to reading digits, so
    /// entries written under a template the user has since changed stay
    /// visible.
    let pattern: JournalPathPattern?

    init(root: URL, pattern: JournalPathPattern? = nil) {
        self.root = root
        self.pattern = pattern
    }

    /// One journal entry: the `## HH:MM` heading and everything under it.
    struct Entry: Identifiable, Sendable {
        let day: String
        /// ISO date from the filename, or nil. Sorts chronologically as text.
        let key: String?
        let time: String
        let text: String
        /// The file this came out of. An entry can't be identified by its
        /// timestamp: a day's file routinely holds two entries at the same
        /// `## HH:MM`, and a date can span two files when the path template
        /// has changed under the user.
        let fileURL: URL
        /// Position in that file, counting only entries with a body.
        let ordinal: Int
        /// Every line the entry owns, heading included, as indices into the
        /// file split on "\n". This is what makes an edit or a delete a
        /// *splice* — the other bytes of the file are never re-rendered, so
        /// blank lines, trailing spaces and anything the user typed in
        /// another editor survive untouched.
        let lineRange: Range<Int>
        /// The lines under the heading. Same range minus the heading line,
        /// or the whole span for an entry that has no heading.
        let bodyLineRange: Range<Int>

        var id: String { "\(fileURL.path)#\(ordinal)" }
    }

    /// A date that has something in it, and the file (or files) holding it.
    struct Day: Identifiable, Sendable {
        /// ISO `yyyy-MM-dd`, straight off the filenames.
        let key: String
        /// Oldest first — append-only files are chronological by
        /// construction, so reading them in write order is the honest order.
        let files: [URL]

        var id: String { key }
    }

    /// Extensions treated as journal notes.
    ///
    /// `.md` is the default and the common case; `.markdown` and `.txt` are
    /// here because a journal that already exists usually predates this app,
    /// and refusing to see somebody's notes over a three-letter difference is
    /// not a defensible reason to show them an empty calendar.
    static let noteExtensions: Set<String> = ["md", "markdown", "txt"]

    /// A note in the archive, with the date it represents and when it last
    /// changed.
    struct File: Sendable {
        let url: URL
        /// nil for a filename with no date in it.
        let key: String?
        let modified: Date
    }

    /// Reads the journal — recent entries by default, filtered when asked.
    ///
    /// Rewritten after it "couldn't see any entries" in real use. It was a
    /// pure word search, so the questions people actually ask — "what have I
    /// journalled", "what did I write yesterday", "show me my entries" — carry
    /// no words that appear in the text and matched nothing. The model then
    /// reported, accurately by its own lights, that the journal was empty.
    ///
    /// So: no query means "the most recent entries", which is the common case;
    /// `daysBack` scopes by date; a query still searches. And it reads whole
    /// entries rather than single matching lines, because an entry is the unit
    /// a person wrote and a lone line out of one is close to useless.
    func read(query: String, daysBack: Int? = nil) -> String {
        let dated = datedFiles()
        guard !dated.isEmpty else { return "There are no journal files yet." }

        let terms = ChatSearch.terms(in: query)
        var scope = ""
        var candidates = dated

        if let daysBack, daysBack > 0 {
            let calendar = Calendar.current
            let cutoff = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -(daysBack - 1), to: Date()) ?? Date())
            // Formatted once, then compared as text — see `dateKey`.
            let cutoffKey = Self.isoFormatter.string(from: cutoff)
            // Filter by the date in the *filename* — no file is opened to
            // decide it's out of range.
            candidates = dated.filter { ($0.key ?? "") >= cutoffKey }
            scope = daysBack == 1 ? " from today" : " from the last \(daysBack) days"
            if candidates.isEmpty {
                return "No journal entries\(scope). The journal goes back to \(oldestDescription(dated)) — try without a day limit."
            }
        }

        if terms.isEmpty {
            // The common case, and the one that used to read the whole
            // archive to answer "what did I write lately". Files are already
            // newest-first, so stop as soon as there are enough entries.
            var collected: [Entry] = []
            for file in candidates {
                collected.append(contentsOf: parseEntries(in: file.url))
                if daysBack == nil, collected.count >= recentEntryLimit { break }
            }
            collected.sort { ($0.key ?? "", $0.time) > ($1.key ?? "", $1.time) }
            guard !collected.isEmpty else { return "The journal files are empty." }
            let shown = collected.prefix(recentEntryLimit)
            let noun = shown.count == 1 ? "entry" : "entries"
            return "The \(shown.count) most recent journal \(noun)\(scope):\n\n" + render(shown)
        }

        // A search still reads every candidate file: ranking across the whole
        // archive is the point, and stopping early would quietly return the
        // most *recent* matches rather than the best ones. Measured at 178 ms
        // over a five-year, 1,613-file archive — fine inside a tool call, and
        // the thing to revisit (with a real index) if that stops being true.
        let entries = candidates.flatMap { parseEntries(in: $0.url) }
        guard !entries.isEmpty else { return "The journal files are empty." }
        let matched = entries.filter { ChatSearch.score($0.text, terms: terms) > 0 }
        let full = matched.filter { ChatSearch.score($0.text, terms: terms) == terms.count }
        var chosen = full.isEmpty ? matched : full
        guard !chosen.isEmpty else {
            let noun = entries.count == 1 ? "entry" : "entries"
            return "No journal entries match “\(query)”\(scope). "
                + "There are \(entries.count) \(noun) to search, going back to "
                + "\(oldestDescription(dated)) — try different words, or ask without "
                + "a search to see the most recent."
        }
        chosen.sort { ($0.key ?? "", $0.time) > ($1.key ?? "", $1.time) }
        let shown = chosen.prefix(recentEntryLimit)
        let noun = chosen.count == 1 ? "entry" : "entries"
        var header = "\(chosen.count) journal \(noun) matching “\(query)”\(scope)"
        if chosen.count > shown.count {
            header += ", newest \(shown.count) shown"
        }
        return header + ":\n\n" + render(shown)
    }

    private let recentEntryLimit = 12

    private func render(_ entries: ArraySlice<Entry>) -> String {
        entries
            .map { entry in
                let when = entry.time.isEmpty ? entry.day : "\(entry.day), \(entry.time)"
                return "[\(when)]\n\(entry.text)"
            }
            .joined(separator: "\n\n")
    }

    private func oldestDescription(_ files: [File]) -> String {
        guard let oldest = files.last else { return "an unknown date" }
        guard let key = oldest.key, let date = Self.isoFormatter.date(from: key) else {
            return oldest.url.deletingPathExtension().lastPathComponent
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    /// One shared formatter, used only for the cutoff and for display — never
    /// per file.
    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Splits one journal file into entries.
    func parseEntries(in url: URL) -> [Entry] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parseEntries(in: contents, url: url)
    }

    /// The same, over text already in hand.
    ///
    /// Split out because an edit has to parse the *exact* bytes it is about to
    /// splice. Reading the file once and parsing that string keeps the line
    /// numbers and the file in step; reading it twice does not.
    static func parseEntries(in contents: String, url: URL) -> [Entry] {
        let fileKey = dateKey(from: url)
        var day = url.deletingPathExtension().lastPathComponent
        var time = ""
        var body: [String] = []
        var entries: [Entry] = []
        // Where the entry being accumulated begins. `start` is its heading
        // line, so deleting an entry takes its `## 14:32` with it rather than
        // leaving a heading with nothing under it; `bodyStart` is the first
        // line below the heading.
        var start = 0
        var bodyStart = 0

        func flush(end: Int) {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeAll()
            guard !text.isEmpty else { return }
            entries.append(Entry(day: day, key: fileKey, time: time, text: text,
                                 fileURL: url, ordinal: entries.count,
                                 lineRange: start..<end, bodyLineRange: bodyStart..<end))
        }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let text = String(line)
            if text.hasPrefix("## ") {
                flush(end: index)
                time = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
                start = index
                bodyStart = index + 1
                continue
            }
            if text.hasPrefix("# ") {
                flush(end: index)
                day = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
                // The file's own title line belongs to no entry, so the next
                // one starts below it.
                time = ""
                start = index + 1
                bodyStart = index + 1
                continue
            }
            body.append(text)
        }
        flush(end: lines.count)
        return entries
    }

    /// The ISO date encoded in a journal filename, as a plain string.
    ///
    /// Deliberately a `String` and not a `Date`. ISO-8601 dates sort
    /// lexicographically in chronological order, so ordering and day-scoping
    /// both work on the raw text — and building a `Date` per file does not.
    /// The first version created a `DateFormatter` inside this function, i.e.
    /// once per file: on a five-year, 1,613-file archive that alone accounted
    /// for most of a 124 ms call, before a single entry was read. Scanning for
    /// the digits by hand costs nothing and needs no formatter at all.
    ///
    /// The date a file represents, read from its name *and* the folders it sits
    /// in below the journal root.
    ///
    /// The filename alone isn't enough, because a perfectly ordinary layout
    /// puts the date in the path: `{yyyy}/{MM}/{dd}.md` gives a file called
    /// `19.md`, which says nothing on its own. Only components *below the root*
    /// are considered — the root is wherever the user pointed their template,
    /// and a home directory or a backup folder with a year in its name has no
    /// business dating their entries.
    static func dateKey(for url: URL, root: URL, pattern: JournalPathPattern? = nil) -> String? {
        let relative = relativePath(of: url, under: root)
        // The template first, because it *knows*; digits only when the file
        // isn't one the current template would have written.
        if let key = pattern?.dayKey(forRelativePath: relative) { return key }
        return dateKey(forRelativePath: components(ofRelativePath: relative))
    }

    /// The path of `url` below `root`, extension and all — which is what the
    /// template describes.
    static func relativePath(of url: URL, under root: URL) -> String {
        let filePath = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        return filePath.hasPrefix(rootPath)
            ? String(filePath.dropFirst(rootPath.count))
            : url.lastPathComponent
    }

    /// The same, split into components with the extension dropped — what the
    /// digit-reading fallback works over.
    static func relativeComponents(of url: URL, under root: URL) -> [String] {
        components(ofRelativePath: relativePath(of: url, under: root))
    }

    static func components(ofRelativePath relative: String) -> [String] {
        var components = relative.split(separator: "/").map(String.init)
        if let last = components.last {
            components[components.count - 1] = (last as NSString).deletingPathExtension
        }
        return components
    }

    /// Work out a date from path components, cheapest test first.
    ///
    /// 1. A full `yyyy-MM-dd` anywhere in the filename — the common case, and
    ///    the only one the original version handled.
    /// 2. Eight digits together, `yyyyMMdd`.
    /// 3. Otherwise, the runs of digits across the components in order: the
    ///    first four-digit run is the year, and the next two 1-or-2-digit runs
    ///    are the month and the day. That covers `{yyyy}/{MM}/{dd}`,
    ///    `{yyyy}/{MM}-{MMMM}/{dd}`, `{yyyy}-{MM}/{dd}` and — for free, since
    ///    only digits are looked at — `yyyy_MM_dd`.
    ///
    /// Day-first (`19-09-2026`) is deliberately *not* recognised: it can't be
    /// told from month-first, and guessing wrong files an entry under a day it
    /// didn't happen on. Nothing here parses a `Date`; see `dateKey(from:)` for
    /// why that matters.
    static func dateKey(forRelativePath components: [String]) -> String? {
        guard let name = components.last else { return nil }
        if let iso = dateKey(inName: name) { return iso }

        var runs: [(value: Int, digits: Int)] = []
        for component in components {
            var digits = 0
            var value = 0
            func flush() {
                if digits > 0 { runs.append((value, digits)) }
                digits = 0
                value = 0
            }
            for byte in component.utf8 {
                if byte >= 48, byte <= 57 {
                    digits += 1
                    value = value * 10 + Int(byte - 48)
                } else {
                    flush()
                }
            }
            flush()
        }

        // yyyyMMdd, on its own.
        for run in runs where run.digits == 8 {
            return key(year: run.value / 10_000,
                       month: (run.value / 100) % 100,
                       day: run.value % 100)
        }

        guard let yearIndex = runs.firstIndex(where: { $0.digits == 4 }) else { return nil }
        let rest = runs[runs.index(after: yearIndex)...].filter { $0.digits == 1 || $0.digits == 2 }
        guard rest.count >= 2 else { return nil }
        return key(year: runs[yearIndex].value, month: rest[rest.startIndex].value,
                   day: rest[rest.index(after: rest.startIndex)].value)
    }

    /// Zero-padded `yyyy-MM-dd`, or nil if the numbers aren't a plausible date.
    /// Built by hand rather than by a `DateFormatter` — see `dateKey(from:)`.
    private static func key(year: Int, month: Int, day: Int) -> String? {
        guard year >= 1000, year <= 9999, month >= 1, month <= 12, day >= 1, day <= 31
        else { return nil }
        let monthText = month < 10 ? "0\(month)" : "\(month)"
        let dayText = day < 10 ? "0\(day)" : "\(day)"
        return "\(year)-\(monthText)-\(dayText)"
    }

    /// nil for a filename with no date in it — such a file still works, it
    /// just sorts last and can't be day-filtered.
    static func dateKey(from url: URL) -> String? {
        dateKey(inName: url.deletingPathExtension().lastPathComponent)
    }

    /// A full `yyyy-MM-dd` anywhere in one piece of text, found by scanning for
    /// the digits rather than by parsing a date.
    static func dateKey(inName name: String) -> String? {
        let bytes = Array(name.utf8)
        guard bytes.count >= 10 else { return nil }
        func isDigit(_ i: Int) -> Bool { bytes[i] >= 48 && bytes[i] <= 57 }
        for start in 0...(bytes.count - 10) {
            guard isDigit(start), isDigit(start + 1), isDigit(start + 2), isDigit(start + 3),
                  bytes[start + 4] == 45,  // "-"
                  isDigit(start + 5), isDigit(start + 6),
                  bytes[start + 7] == 45,
                  isDigit(start + 8), isDigit(start + 9)
            else { continue }
            // A run of digits longer than the date itself isn't a date — it's a
            // serial number that happens to contain dashes.
            let key = String(decoding: bytes[start..<(start + 10)], as: UTF8.self)
            guard start == 0 || !isDigit(start - 1) else { continue }
            return key
        }
        return nil
    }

    /// Every `.md` under the journal root, newest first, paired with the date
    /// in its filename.
    ///
    /// Ordering by filename rather than by content is what makes "show me my
    /// recent entries" cheap: on a five-year archive the old version parsed all
    /// 1,613 files to answer it (184 ms); reading them newest-first and
    /// stopping once there are enough takes 1 ms. Files whose names carry no
    /// date sort last — they still work, they just can't be date-filtered.
    /// Modification dates ride along from the same walk (one prefetched
    /// resource key, not a stat per file) because they are the only honest way
    /// to order two files carrying the *same* date — which happens as soon as
    /// someone changes their path template, and has already happened in the
    /// author's own archive.
    ///
    /// `.skipsHiddenFiles` has a consequence worth knowing: an iCloud-evicted
    /// file is a hidden `.2026-09-15.md.icloud` placeholder, so an evicted day
    /// simply isn't listed. Fixable with `startDownloadingUbiquitousItem` if
    /// anyone hits it.
    func datedFiles() -> [File] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { Self.noteExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                File(url: url,
                     key: Self.dateKey(for: url, root: root, pattern: pattern),
                     modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast)
            }
            .sorted {
                let left = $0.key ?? "", right = $1.key ?? ""
                // `sorted` isn't stable, so two files sharing a date need a
                // defined tiebreak or their order changes between calls.
                return left == right ? $0.modified > $1.modified : left > right
            }
    }

    /// Every date the archive holds something for, newest first.
    ///
    /// The sidebar's entire data source, and it opens no files: the dates come
    /// off the filenames (see `dateKey(from:)` for why that's a byte scan and
    /// not a `DateFormatter`), which is what keeps a calendar over a five-year
    /// archive free rather than a full parse.
    ///
    /// Files whose names carry no date are left out — there is no day to file
    /// them under. Within a day, files are oldest-first: an append-only file is
    /// chronological by construction, so write order is reading order.
    func days() -> [Day] {
        var byKey: [String: [File]] = [:]
        for file in datedFiles() {
            guard let key = file.key else { continue }
            byKey[key, default: []].append(file)
        }
        return byKey
            .map { key, files in
                Day(key: key, files: files.sorted { $0.modified < $1.modified }.map(\.url))
            }
            .sorted { $0.key > $1.key }
    }
}
