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

    /// A `.md` in the archive, with the date in its name and when it last
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
    /// nil for a filename with no date in it — such a file still works, it
    /// just sorts last and can't be day-filtered.
    static func dateKey(from url: URL) -> String? {
        let name = Array(url.deletingPathExtension().lastPathComponent.utf8)
        guard name.count >= 10 else { return nil }
        func isDigit(_ i: Int) -> Bool { name[i] >= 48 && name[i] <= 57 }
        for start in 0...(name.count - 10) {
            guard isDigit(start), isDigit(start + 1), isDigit(start + 2), isDigit(start + 3),
                  name[start + 4] == 45,  // "-"
                  isDigit(start + 5), isDigit(start + 6),
                  name[start + 7] == 45,
                  isDigit(start + 8), isDigit(start + 9)
            else { continue }
            return String(decoding: name[start..<(start + 10)], as: UTF8.self)
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
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { url in
                File(url: url,
                     key: Self.dateKey(from: url),
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
