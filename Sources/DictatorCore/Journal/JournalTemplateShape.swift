import Foundation

/// What a user's journal templates let the window do.
///
/// The templates are free text — that's the point of them, and why the journal
/// drops into an existing vault — but the window makes two assumptions the
/// hotkey never had to: that a file's name says which day it is, and that
/// entries within it can be told apart. Both are true of the defaults and of
/// every template that looks like the defaults. Neither is guaranteed.
///
/// So they're checked, deterministically, by resolving the template and looking
/// at what comes out. Guessing from the template's source text would mean
/// re-implementing the date-pattern language; rendering it asks the same code
/// the writer uses.
enum JournalTemplateShape {

    /// Sentinel standing in for the dictation. Chosen to be something no date
    /// pattern can produce and no one would type.
    private static let sentinel = "\u{2063}DICTATION\u{2063}"

    /// Can a day be found from a filename?
    ///
    /// The calendar needs each file to say which day it is, which is true as
    /// long as the template names a year, a month and a day somewhere below the
    /// root — in the filename, in the folders, or spread across both. Month
    /// names and day-first orders are fine, because `JournalPathPattern` reads
    /// the template rather than guessing at the result.
    ///
    /// What can't work is a template with no day in it: one long `journal.md`,
    /// or a monthly `{yyyy}-{MM}.md`. Those are perfectly good journals, they
    /// just have no days to page through.
    ///
    /// A false answer here is cheap: entries are appended the same way
    /// regardless, and the assistant still reads the whole archive.
    static func daysAreFindable(pathTemplate: String) -> Bool {
        // Asked of the template itself rather than of a rendered example: the
        // question is whether the template *names* a year, a month and a day
        // below the root, which is exactly what the matcher is built from.
        // Rendering one date and looking for digits could only ever guess.
        JournalPathPattern.make(pathTemplate: pathTemplate)?.identifiesADay ?? false
    }

    /// Can one entry be told from the next?
    ///
    /// `JournalArchive` splits on `## ` and `# ` headings, so an entry template
    /// that writes a bullet, or puts the dictation above its heading, produces
    /// a file that parses as one entry per file or as entries with the wrong
    /// timestamps. Rather than pretend, the window shows such a day whole — it
    /// can still be read and added to, just not edited entry by entry.
    static func entriesAreParseable(entryTemplate: String) -> Bool {
        let rendered = JournalWriter.resolve(template: entryTemplate,
                                             date: referenceDate,
                                             text: sentinel,
                                             appName: "Some App")
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headingIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return false }
        let heading = lines[headingIndex]
        guard heading.hasPrefix("## ") || heading.hasPrefix("# ") else { return false }
        // The dictation has to land *below* the heading. Above it, every entry
        // would be filed under the previous entry's timestamp.
        guard let textIndex = lines.firstIndex(where: { $0.contains(sentinel) }) else { return false }
        return textIndex > headingIndex
    }

    /// A fixed date, so the answer doesn't change with the clock. Midday on a
    /// two-digit day of a two-digit month: a template using `{d}` or `{M}`
    /// renders the same width as one using `{dd}` or `{MM}`, so neither is
    /// accidentally judged on a one-digit day.
    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 12
        components.day = 25
        components.hour = 14
        components.minute = 32
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }()
}
