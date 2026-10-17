import Foundation

/// How much of an existing journal a given path template can actually read.
///
/// Changing the file template is the one journal setting that can cost you
/// something, and the cost isn't obvious: files already on disk were written in
/// the old shape, and the new template won't match them. What saves most people
/// is the fallback — a file the template doesn't recognise is still dated by
/// reading the digits out of its path — so in practice a change from one
/// numeric layout to another loses nothing at all.
///
/// "Most people" is not an answer to give someone about their own diary, so
/// this counts. It's the same walk and the same two readers the journal window
/// uses, run against whatever template is in the box right now, which makes the
/// consequence of an edit visible while it's being made rather than afterwards.
struct JournalCoverage: Equatable {
    /// Files the template itself recognises — read exactly.
    var matched = 0
    /// Files the template doesn't match, but whose date can still be read from
    /// the digits in their path. These appear in the window as normal.
    var dated = 0
    /// Files with no readable date. These are still on disk, and the assistant
    /// still searches them, but they can't be put on a calendar.
    var undated = 0
    /// A few of the unreadable ones, to name in the warning — a count alone
    /// doesn't tell you whether it's the file you care about.
    var undatedExamples: [String] = []
    /// Whether the template names a day at all. A template without one is a
    /// perfectly good journal and a calendar with nothing to show, so it has to
    /// be said separately from anything about the files.
    var templateIdentifiesADay = false

    var total: Int { matched + dated + undated }
    var isEmpty: Bool { total == 0 }

    /// Walk an archive and classify every note in it.
    ///
    /// `nonisolated` and taking plain values so it can run off the main actor —
    /// it's the same directory walk the window does, and Settings shouldn't
    /// stutter while someone types in the template field.
    nonisolated static func measure(root: URL, pattern: JournalPathPattern?) -> JournalCoverage {
        var coverage = JournalCoverage()
        coverage.templateIdentifiesADay = pattern?.identifiesADay ?? false
        let archive = JournalArchive(root: root)
        for file in archive.datedFiles() {
            let relative = JournalArchive.relativePath(of: file.url, under: root)
            if pattern?.dayKey(forRelativePath: relative) != nil {
                coverage.matched += 1
            } else if JournalArchive.dateKey(
                forRelativePath: JournalArchive.components(ofRelativePath: relative)) != nil {
                coverage.dated += 1
            } else {
                coverage.undated += 1
                if coverage.undatedExamples.count < 3 {
                    coverage.undatedExamples.append(relative)
                }
            }
        }
        return coverage
    }

    // MARK: - What to say about it

    enum Tone {
        case fine
        case warning
    }

    var tone: Tone {
        (undated > 0 || !templateIdentifiesADay) ? .warning : .fine
    }

    /// One sentence, in the terms the user thinks in: their entries, not our
    /// matching strategy.
    var summary: String {
        // Said first and on its own, because it isn't about the files at all —
        // no template without a day can drive a calendar, however readable
        // everything on disk happens to be.
        guard templateIdentifiesADay else {
            return "This template doesn't include a day, so the journal window can't show a "
                + "calendar. Entries are still written, and the assistant can still read them."
        }
        if isEmpty {
            return "Nothing written yet — this is where entries will go."
        }
        if undated == 0 {
            if dated == 0 {
                return "All \(count(total, "file")) in your journal match this template."
            }
            // The reassuring case, and the common one: the template changed and
            // nothing was lost, because the dates are still readable.
            return "\(count(total, "file")) in your journal. "
                + "\(count(dated, "older file")) \(dated == 1 ? "doesn't" : "don't") match this "
                + "template, but \(dated == 1 ? "its date is" : "their dates are") still readable, "
                + "so everything still appears in the journal window."
        }
        return "\(count(undated, "file")) in your journal can't be dated and won't appear in the "
            + "journal window. Nothing is deleted — they stay on disk and the assistant can still "
            + "read them."
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }

    /// Named so the user can go and look, because a count doesn't tell you
    /// whether the one you care about is in it.
    var examplesLine: String? {
        guard !undatedExamples.isEmpty else { return nil }
        let names = undatedExamples.joined(separator: ", ")
        return undated > undatedExamples.count ? "\(names), …" : names
    }
}
