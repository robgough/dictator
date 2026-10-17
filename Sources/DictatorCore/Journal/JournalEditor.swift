import Foundation

/// Changing an entry that has already been written.
///
/// Everything else in the journal only ever *appends* — `JournalWriter` opens
/// the file, seeks to the end and writes, deliberately, so it can't fight a
/// sync client and can't cost anything on a long file. This is the one place
/// that rewrites, because "fix a typo without opening a Markdown file" is most
/// of why the journal window exists.
///
/// Three rules make that safe enough to ship:
///
/// 1. **It's a splice, not a re-render.** The file is read, the lines one entry
///    owns are replaced or removed, and the rest is written back byte for byte.
///    Nothing reformats — blank lines, trailing spaces, a heading someone typed
///    by hand in another editor, and the shape of every neighbouring entry all
///    survive, because they are never parsed into anything and back.
/// 2. **It refuses when the file moved under it.** These are plain files in
///    somebody's vault, quite possibly open in Obsidian with a sync client
///    watching. Every operation re-reads, re-parses and checks the entry still
///    says what the caller thought it said. If it doesn't, nothing is written.
/// 3. **Every change is undoable, exactly.** An `Undo` carries the whole file
///    as it was and as we left it; applying it checks the file is still the one
///    we wrote before restoring. There is no Trash for part of a file, so this
///    is the only safety net there is.
///
/// Foundation only, and no app types, so `scratch/journal-edit-check` can
/// attack it directly — which it does, including the "changed underneath"
/// races and the round-trip of the author's real archive.
enum JournalEditor {

    /// Enough to put a file back exactly as it was.
    ///
    /// Whole-file rather than a reverse splice: an undo has to be certain, and
    /// comparing what's on disk against what we wrote is the only check that
    /// can't be fooled by an edit elsewhere in the file.
    struct Undo {
        let url: URL
        /// The file before the change.
        let before: String
        /// The file as this editor left it. If what's on disk no longer matches
        /// this, somebody else has written since and the undo is refused.
        let after: String
        /// The entry's text, so a failed undo can still hand the words back.
        let text: String
        /// For the UI: "14:32", or empty for an entry with no heading.
        let time: String
    }

    enum EditError: LocalizedError, Equatable {
        case unreadable(String)
        case entryNotFound
        case changedUnderneath
        case emptyText
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "Couldn't read \(name)."
            case .entryNotFound:
                return "That entry isn't in the file any more."
            case .changedUnderneath:
                return "The file changed somewhere else since this was loaded, so nothing was written. It's been reloaded — try again."
            case .emptyText:
                return "An entry can't be empty. Delete it instead."
            case .writeFailed(let reason):
                return "Couldn't save the change: \(reason)"
            }
        }
    }

    // MARK: - Editing

    /// Replace one entry's words, leaving its heading and the rest of the file
    /// alone.
    ///
    /// `expecting` is what the caller believes the entry currently says; the
    /// write is refused if the file disagrees. That check is the entry's
    /// content rather than a modification date because a date says only that
    /// *something* changed — this says whether the thing being edited did.
    @discardableResult
    static func replace(ordinal: Int,
                        in url: URL,
                        expecting: String,
                        with newText: String) throws -> Undo {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyText }

        let (before, entry) = try locate(ordinal: ordinal, in: url, expecting: expecting)
        var lines = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Replace only the lines that actually carry words. The blank line the
        // entry template puts under the heading, and any blank lines before the
        // next one, are part of the file's spacing rather than the entry's
        // text — rewriting them would reflow a file the user may be reading in
        // another editor.
        let body = entry.bodyLineRange
        let written = lines[body].enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let first = written.first?.offset, let last = written.last?.offset else {
            throw EditError.entryNotFound
        }
        let target = (body.lowerBound + first)...(body.lowerBound + last)
        lines.replaceSubrange(target, with: trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))

        let after = lines.joined(separator: "\n")
        try write(after, to: url)
        return Undo(url: url, before: before, after: after, text: entry.text, time: entry.time)
    }

    /// Remove an entry, heading and all.
    ///
    /// The heading goes with it on purpose: a `## 14:32` left standing over
    /// nothing reads as a lost entry, and the next parse would skip it anyway.
    @discardableResult
    static func delete(ordinal: Int, in url: URL, expecting: String) throws -> Undo {
        let (before, entry) = try locate(ordinal: ordinal, in: url, expecting: expecting)
        var lines = before.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeSubrange(entry.lineRange)
        let after = lines.joined(separator: "\n")
        try write(after, to: url)
        return Undo(url: url, before: before, after: after, text: entry.text, time: entry.time)
    }

    /// Put a file back the way it was, if nobody else has touched it since.
    static func undo(_ undo: Undo) throws {
        let current = try read(undo.url)
        guard current == undo.after else { throw EditError.changedUnderneath }
        try write(undo.before, to: undo.url)
    }

    // MARK: - Plumbing

    /// Read, parse, and check the entry is still the one the caller means.
    ///
    /// Returns the file's exact text alongside the entry so the caller splices
    /// the same bytes it just validated. Reading it a second time would open a
    /// window — small, but this is somebody's diary.
    private static func locate(ordinal: Int,
                               in url: URL,
                               expecting: String) throws -> (contents: String, entry: JournalArchive.Entry) {
        let contents = try read(url)
        let entries = JournalArchive.parseEntries(in: contents, url: url)
        guard ordinal >= 0, ordinal < entries.count else { throw EditError.entryNotFound }
        let entry = entries[ordinal]
        guard entry.text == expecting else { throw EditError.changedUnderneath }
        return (contents, entry)
    }

    private static func read(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw EditError.unreadable(url.lastPathComponent)
        }
    }

    /// Atomic replace. This changes the file's inode, which is why the window's
    /// watcher re-opens by path rather than holding a descriptor — and it is
    /// what every other Markdown editor on the machine does to the same file.
    private static func write(_ contents: String, to url: URL) throws {
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw EditError.writeFailed(error.localizedDescription)
        }
    }
}
