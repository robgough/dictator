import Foundation

/// Appends a dictation to a Markdown file on disk instead of pasting it.
///
/// Journal dictation has its own hotkey and never touches the focused app —
/// the point is to capture a thought without first finding somewhere to put
/// it. Where it lands is entirely the user's choice, because everyone's notes
/// live somewhere different (an Obsidian vault, a daily-notes folder, one
/// long file): both the path and the entry are templates.
///
/// **Template syntax.** Anything in braces is a
/// [Unicode date-format pattern](https://www.unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table)
/// resolved against the moment of dictation, so `{yyyy}-{MM}-{dd}` is
/// `2026-09-13` and `{EEEE}` is `Sunday`. Two tokens are special-cased
/// instead: `{text}` (the dictation) and `{app}` (the app that was in front).
/// Treating braces as date patterns rather than a fixed keyword list means
/// week numbers, quarters, 12-hour clocks and locale month names all work
/// without anyone having to add them.
enum JournalWriter {

    struct Written {
        let url: URL
        /// True when this write created the file (so the caller can say
        /// "started today's note" rather than "added to it").
        let createdFile: Bool
    }

    enum JournalError: LocalizedError {
        case emptyPath
        case notAFile(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "No journal file is set. Choose one in Settings → General → Journal."
            case .notAFile(let path):
                return "The journal path points at a folder, not a file: \(path)"
            }
        }
    }

    /// Default templates. A dated file per day with an hour:minute heading per
    /// entry is the shape almost every notes app already uses, so it drops
    /// into an existing vault without configuration.
    ///
    /// The year/month folders matter more than they look: journalling daily
    /// puts 365 files a year in one directory, and after two years that
    /// folder is unusable in Finder. Nesting costs one extra click and keeps
    /// it browsable indefinitely.
    static let defaultPathTemplate = "~/Documents/Dictator/Journal/{yyyy}/{MM}-{MMMM}/{yyyy}-{MM}-{dd}.md"
    static let defaultHeaderTemplate = "# {EEEE} {d} {MMMM} {yyyy}\n"
    static let defaultEntryTemplate = "\n## {HH}:{mm}\n\n{text}\n"

    /// Resolve a template into a concrete string.
    ///
    /// `text` and `app` are nil for the path and header templates — the file
    /// name shouldn't depend on the dictation's contents — in which case those
    /// tokens resolve to empty rather than leaking a literal "{text}" into a
    /// filename.
    static func resolve(template: String,
                        date: Date = Date(),
                        text: String? = nil,
                        appName: String? = nil) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                // Unbalanced brace: emit the rest verbatim rather than
                // swallowing the user's text.
                out += rest[open...]
                return out
            }
            let token = String(rest[afterOpen..<close])
            switch token {
            case "text":
                out += text ?? ""
            case "app":
                out += appName ?? ""
            case "":
                out += "{}"
            default:
                out += formatted(date, pattern: token)
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// Absolute file URL a path template resolves to right now. Exposed so
    /// Settings can show a live preview under the field — a template language
    /// nobody can see the output of is a template language nobody uses.
    /// `@MainActor` because a relative template resolves against
    /// `SyncedStorage.directory`, which is main-actor state. Both callers —
    /// the pipeline's delivery step and the Settings preview — are already
    /// there. Template *resolution* itself stays nonisolated, so the default
    /// constants below can still be used as settings defaults.
    @MainActor
    static func resolvedURL(pathTemplate: String, date: Date = Date()) throws -> URL {
        let resolved = resolve(template: pathTemplate, date: date)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else { throw JournalError.emptyPath }
        let expanded = (resolved as NSString).expandingTildeInPath
        // A relative template is resolved against the synced folder, so
        // "Journal/{yyyy}.md" follows the user's other synced data rather than
        // landing wherever the process happened to be launched from.
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else {
            url = SyncedStorage.directory.appendingPathComponent(expanded)
        }
        guard !url.hasDirectoryPath else { throw JournalError.notAFile(url.path) }
        return url
    }

    /// Append one dictation. Creates intermediate directories and the file
    /// itself, writing the header template only when the file is new.
    @discardableResult
    @MainActor
    static func append(text: String,
                       pathTemplate: String,
                       headerTemplate: String,
                       entryTemplate: String,
                       appName: String?,
                       date: Date = Date()) throws -> Written {
        let url = try resolvedURL(pathTemplate: pathTemplate, date: date)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existed = FileManager.default.fileExists(atPath: url.path)
        var payload = ""
        if !existed {
            payload += resolve(template: headerTemplate, date: date, appName: appName)
        }
        payload += resolve(template: entryTemplate, date: date, text: text, appName: appName)
        guard let data = payload.data(using: .utf8) else {
            return Written(url: url, createdFile: false)
        }

        if existed {
            // Append in place. Rewriting the whole file would make a year-long
            // journal quadratic, and would fight any sync client watching it.
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        return Written(url: url, createdFile: !existed)
    }

    // MARK: - Date formatting

    /// One formatter per pattern. `DateFormatter` is expensive to build and a
    /// journal write resolves several patterns per entry, every entry.
    private static let formatterCache = FormatterCache()

    private static func formatted(_ date: Date, pattern: String) -> String {
        formatterCache.formatter(for: pattern).string(from: date)
    }

    /// `DateFormatter` isn't Sendable and the cache is reached from whichever
    /// context is delivering a dictation, so the dictionary is lock-guarded
    /// rather than actor-isolated — a lock is cheaper here than making every
    /// template resolution async.
    private final class FormatterCache: @unchecked Sendable {
        private var cache: [String: DateFormatter] = [:]
        private let lock = NSLock()

        func formatter(for pattern: String) -> DateFormatter {
            lock.lock()
            defer { lock.unlock() }
            if let existing = cache[pattern] { return existing }
            let formatter = DateFormatter()
            // Fixed locale: a template is a filename, and month names or
            // digits changing with the system locale would scatter entries
            // across differently-named files.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            cache[pattern] = formatter
            return formatter
        }
    }
}
