import Foundation

/// The user's own path template, turned round and used to *read* their journal.
///
/// The archive used to guess a date out of whatever digits it could find in a
/// path. That works for the common shapes and quietly fails for the rest: a
/// month written as "September" carries no number, and `19-09-2026` can't be
/// told from `09-19-2026` by looking at it.
///
/// But we know exactly what a journal file looks like, because we wrote it —
/// the path template says so. Read backwards, `{yyyy}/{MMMM}/{d}.md` is not an
/// ambiguous pile of digits; it is a year, then a month *by name*, then a day.
/// So this compiles the template into a matcher: literals match literally, and
/// each `{pattern}` becomes a capture that knows which part of a date it holds.
///
/// Two things follow that the guesswork couldn't do:
///
/// * **Month names and day-first dates work**, because the template removes the
///   ambiguity rather than the reader having to resolve it.
/// * **A file that isn't a journal entry doesn't match**, so a stray note in
///   the same folder can't invent a day.
///
/// Guessing remains as a fallback, and that matters: when someone changes their
/// template, every file written under the old one stops matching, and those are
/// real entries that must not vanish from the calendar.
///
/// Foundation only, like `JournalArchive`, so `scratch/journal-edit-check` can
/// exercise it directly.
struct JournalPathPattern {

    /// The part of a date a capture group holds.
    private enum Field {
        case year
        case shortYear
        case month
        case monthName
        case day
    }

    private let regex: NSRegularExpression
    /// Capture group number → what it means. An array rather than a dictionary
    /// keyed by name because a template may use `{yyyy}` more than once — the
    /// default one does — and ICU won't take a repeated group name.
    private let fields: [(group: Int, field: Field)]

    /// True when the template pins down a specific day. `{yyyy}-{MM}.md` is a
    /// perfectly good monthly journal; it just has no days for a calendar.
    let identifiesADay: Bool

    /// Build a matcher for the part of the template below the journal root.
    ///
    /// Returns nil when the template has no date in it at all (one long
    /// `journal.md`), or when it can't be compiled — in both cases the caller
    /// falls back to reading digits.
    init?(templateBelowRoot template: String) {
        var pattern = "^"
        var fields: [(group: Int, field: Field)] = []
        var group = 0

        func capture(_ body: String, as field: Field) {
            group += 1
            fields.append((group, field))
            pattern += "(\(body))"
        }

        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            pattern += NSRegularExpression.escapedPattern(for: String(rest[..<open]))
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                pattern += NSRegularExpression.escapedPattern(for: String(rest[open...]))
                rest = rest[rest.endIndex...]
                break
            }
            let token = String(rest[afterOpen..<close])
            switch token {
            case "yyyy", "YYYY": capture("\\d{4}", as: .year)
            case "yy", "YY": capture("\\d{2}", as: .shortYear)
            case "MM": capture("\\d{2}", as: .month)
            case "M": capture("\\d{1,2}", as: .month)
            case "MMMM", "LLLL": capture(Self.monthNameAlternation(short: false), as: .monthName)
            case "MMM", "LLL": capture(Self.monthNameAlternation(short: true), as: .monthName)
            case "dd": capture("\\d{2}", as: .day)
            case "d": capture("\\d{1,2}", as: .day)
            // Not part of the date, but they still have to be consumed or the
            // literal either side of them won't line up.
            case "EEEE", "eeee", "cccc": pattern += "(?:\(Self.weekdayAlternation(short: false)))"
            case "EEE", "eee", "ccc", "E", "e", "c": pattern += "(?:\(Self.weekdayAlternation(short: true)))"
            case "HH", "hh", "mm", "ss", "DDD": pattern += "\\d{2,3}"
            case "H", "h", "m", "s", "D", "w", "W", "F", "Q", "q": pattern += "\\d{1,3}"
            case "a": pattern += "(?:AM|PM)"
            // Both resolve to nothing when a *path* is worked out — see
            // `JournalWriter.resolvedURL`, which passes neither.
            case "text", "app": break
            case "": pattern += NSRegularExpression.escapedPattern(for: "{}")
            default:
                // Something we don't model. Match anything within one path
                // component so the rest of the template still lines up.
                pattern += "[^/]*?"
            }
            rest = rest[rest.index(after: close)...]
        }
        pattern += NSRegularExpression.escapedPattern(for: String(rest))
        pattern += "$"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              !fields.isEmpty
        else { return nil }
        self.regex = regex
        self.fields = fields
        let has: (Field) -> Bool = { wanted in fields.contains { $0.field == wanted } }
        self.identifiesADay = (has(.year) || has(.shortYear))
            && (has(.month) || has(.monthName))
            && has(.day)
    }

    /// The day a file holds, or nil if it isn't one of this template's files.
    func dayKey(forRelativePath path: String) -> String? {
        guard identifiesADay else { return nil }
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        guard let match = regex.firstMatch(in: path, options: [], range: range) else { return nil }

        var year: Int?
        var month: Int?
        var day: Int?
        for (group, field) in fields {
            guard group < match.numberOfRanges,
                  let captured = Range(match.range(at: group), in: path)
            else { continue }
            let text = String(path[captured])
            switch field {
            case .year: year = Int(text)
            // A two-digit year is this century. Every alternative is a guess
            // too, and a journal written in the 1900s isn't reaching this code.
            case .shortYear: year = Int(text).map { 2000 + $0 }
            case .month, .day:
                guard let value = Int(text) else { continue }
                if field == .month { month = value } else { day = value }
            case .monthName: month = Self.monthNumber(named: text)
            }
        }

        guard let year, let month, let day,
              year >= 1000, year <= 9999, month >= 1, month <= 12, day >= 1, day <= 31
        else { return nil }
        let monthText = month < 10 ? "0\(month)" : "\(month)"
        let dayText = day < 10 ? "0\(day)" : "\(day)"
        return "\(year)-\(monthText)-\(dayText)"
    }

    // MARK: - Names

    /// Month and weekday names come from `en_US_POSIX`, because that is the
    /// locale `JournalWriter` writes them in — deliberately, so that changing
    /// the system language can't scatter entries across differently-named
    /// files. Reading them back in any other locale would fail to match the
    /// names actually on disk.
    private static let symbols: (months: [String], shortMonths: [String],
                                 weekdays: [String], shortWeekdays: [String]) = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return (formatter.monthSymbols ?? [],
                formatter.shortMonthSymbols ?? [],
                formatter.weekdaySymbols ?? [],
                formatter.shortWeekdaySymbols ?? [])
    }()

    private static func monthNameAlternation(short: Bool) -> String {
        let names = short ? symbols.shortMonths : symbols.months
        return names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }

    private static func weekdayAlternation(short: Bool) -> String {
        let names = short ? symbols.shortWeekdays : symbols.weekdays
        return names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    }

    private static func monthNumber(named name: String) -> Int? {
        let wanted = name.lowercased()
        if let index = symbols.months.firstIndex(where: { $0.lowercased() == wanted }) {
            return index + 1
        }
        if let index = symbols.shortMonths.firstIndex(where: { $0.lowercased() == wanted }) {
            return index + 1
        }
        return nil
    }

    // MARK: - Splitting a template at its root

    /// The fixed folder prefix of a path template — everything before the first
    /// `{`, trimmed back to a directory — and the rest of the template, which is
    /// what describes the files below it.
    ///
    /// The same split `JournalWriter.root` makes, kept here so the matcher and
    /// the walk can't disagree about where the root ends.
    static func split(template: String) -> (root: String, belowRoot: String) {
        let fixed = template.split(separator: "{", maxSplits: 1,
                                   omittingEmptySubsequences: false).first.map(String.init) ?? template
        var root = fixed
        if !root.hasSuffix("/") {
            root = (root as NSString).deletingLastPathComponent
            if !root.isEmpty, !root.hasSuffix("/") { root += "/" }
        }
        let belowRoot = template.hasPrefix(root) ? String(template.dropFirst(root.count)) : template
        return (root, belowRoot)
    }

    /// Build a matcher straight from a whole path template.
    static func make(pathTemplate: String) -> JournalPathPattern? {
        JournalPathPattern(templateBelowRoot: split(template: pathTemplate).belowRoot)
    }
}
