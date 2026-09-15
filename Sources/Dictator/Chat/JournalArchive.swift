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
    struct Entry {
        let day: String
        /// ISO date from the filename, or nil. Sorts chronologically as text.
        let key: String?
        let time: String
        let text: String
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

    private func oldestDescription(_ files: [(url: URL, key: String?)]) -> String {
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
        let fileKey = Self.dateKey(from: url)
        var day = url.deletingPathExtension().lastPathComponent
        var time = ""
        var body: [String] = []
        var entries: [Entry] = []

        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            body.removeAll()
            guard !text.isEmpty else { return }
            entries.append(Entry(day: day, key: fileKey, time: time, text: text))
        }

        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("## ") {
                flush()
                time = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if text.hasPrefix("# ") {
                flush()
                day = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            body.append(text)
        }
        flush()
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
    func datedFiles() -> [(url: URL, key: String?)] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { (url: $0, key: Self.dateKey(from: $0)) }
            .sorted { ($0.key ?? "") > ($1.key ?? "") }
    }
}
