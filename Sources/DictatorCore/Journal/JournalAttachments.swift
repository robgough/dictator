import Foundation

/// Photos in a journal entry.
///
/// A journal is Markdown in somebody's folder, quite possibly a vault, so an
/// image has to be a *file next to the note* with an ordinary Markdown link to
/// it. Anything cleverer — a database, a bundle, an absolute path — would look
/// right in this window and be broken everywhere else the user opens their
/// notes.
///
/// Three decisions worth keeping:
///
/// * **Copied, never moved.** The original is the user's, in their Photos
///   export or their Downloads, and it stays there. Same call
///   `ChatAttachments.attach` makes for the same reason.
/// * **`attachments/` beside the note, not a shared pool.** The link is then
///   always `attachments/<file>` — relative, no `..`, no dependence on where
///   the archive root is, and it resolves identically in Obsidian, Marked and
///   GitHub. It also means a day's folder stays self-contained if the user
///   moves it.
/// * **The file is copied as it is.** No format conversion: HEIC is decoded
///   everywhere on this Mac, and re-encoding somebody's photo to suit one
///   Electron-based editor is not a trade worth making silently.
enum JournalAttachments {

    enum AttachError: LocalizedError {
        case notAnImage(String)
        case copyFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .notAnImage(let name):
                return "\(name) isn't an image."
            case .copyFailed(let name, let reason):
                return "Couldn't copy \(name) into the journal folder: \(reason)"
            }
        }
    }

    /// Reuses the chat's classification rather than keeping a second list of
    /// extensions that would drift from it.
    nonisolated static func isImage(_ url: URL) -> Bool {
        ChatAttachments.kind(of: url) == .image
    }

    /// Copy an image in beside a note and hand back the Markdown that points
    /// at it.
    ///
    /// The filename carries the date and time so images sort with the entries
    /// they belong to when the folder is opened in Finder, and so two photos
    /// called `IMG_0001.jpg` from different days don't collide. Where they
    /// would anyway, `availableURL` numbers the second one — the same
    /// no-clobber rule the chat's attachments use.
    nonisolated static func attach(_ source: URL,
                                   besideNote note: URL,
                                   date: Date = Date()) throws -> String {
        guard isImage(source) else { throw AttachError.notAnImage(source.lastPathComponent) }
        let folder = note.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = ChatFileWriter.availableURL(
                for: folder.appendingPathComponent(fileName(for: source, date: date)))
            try FileManager.default.copyItem(at: source, to: destination)
            return markdown(for: destination)
        } catch let error as AttachError {
            throw error
        } catch {
            throw AttachError.copyFailed(source.lastPathComponent, error.localizedDescription)
        }
    }

    /// `![kitchen](attachments/2026-09-19-1402-kitchen.jpg)`
    ///
    /// The alt text is the original name without its extension, so a reader
    /// that can't show the image still says what it was.
    nonisolated static func markdown(for file: URL) -> String {
        let reference = "\(folderName)/\(file.lastPathComponent)"
        let alt = file.deletingPathExtension().lastPathComponent
        return "![\(alt)](\(escaped(reference)))"
    }

    /// Turn a reference found in an entry back into a file on disk.
    ///
    /// Returns nil when it doesn't resolve — a moved or deleted photo — which
    /// the day view shows as a placeholder rather than silently dropping. An
    /// absolute reference (someone hand-wrote one) is honoured; anything else
    /// is relative to the note, which is what Markdown means by a relative
    /// link.
    nonisolated static func resolve(_ reference: String, relativeTo note: URL) -> URL? {
        let cleaned = unescaped(reference.trimmingCharacters(in: .whitespaces))
        guard !cleaned.isEmpty else { return nil }
        // Anything with a scheme is somebody else's business — a remote image
        // in a journal isn't ours to fetch.
        if cleaned.contains("://") { return nil }
        let expanded = (cleaned as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : note.deletingLastPathComponent().appendingPathComponent(expanded)
        let resolved = url.standardizedFileURL
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    // MARK: - Naming

    static let folderName = "attachments"

    /// `2026-09-19-1402-kitchen.jpg`, with the name reduced to characters that
    /// never need percent-encoding — a link with a raw space in it is a link
    /// half the Markdown renderers in the world get wrong.
    nonisolated static func fileName(for source: URL, date: Date) -> String {
        let stem = sanitised(source.deletingPathExtension().lastPathComponent)
        let ext = source.pathExtension.lowercased()
        let prefix = Self.stampFormatter.string(from: date)
        let name = stem.isEmpty ? "photo" : stem
        return ext.isEmpty ? "\(prefix)-\(name)" : "\(prefix)-\(name).\(ext)"
    }

    nonisolated static func sanitised(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = name.map { character -> Character in
            if allowed.contains(character) { return character }
            return "-"
        }
        // Collapse runs of "-" so "My Photo (1).jpg" doesn't become
        // "My-Photo--1-.jpg".
        var out = ""
        var lastWasDash = false
        for character in mapped {
            if character == "-" {
                if lastWasDash { continue }
                lastWasDash = true
            } else {
                lastWasDash = false
            }
            out.append(character)
        }
        return String(out.drop(while: { $0 == "-" }).reversed().drop(while: { $0 == "-" }).reversed())
            .prefix(60)
            .description
    }

    /// Only the two characters that would break the link syntax itself.
    /// Sanitised names never contain them; a hand-written reference might.
    private nonisolated static func escaped(_ reference: String) -> String {
        reference
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private nonisolated static func unescaped(_ reference: String) -> String {
        reference.removingPercentEncoding ?? reference
    }

    private nonisolated static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}
