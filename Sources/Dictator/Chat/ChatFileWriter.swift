import Foundation

/// Writes files the assistant produces.
///
/// Scoped to one folder on purpose. The model picks the filename, and the model
/// is — by this app's own banner — something that confidently makes things up;
/// letting it choose a *path* means letting it choose `~/.zshrc`. So everything
/// lands in one directory inside the user's synced Dictator folder, where it is
/// visible, backed up with their other Dictator data, and trivially deleted.
///
/// It also never overwrites on the create path — but it no longer *renames*
/// there either. A numbered sibling was the original answer to "write it
/// again", from before `update` existed, and it was measured going wrong in
/// the worst available way: asked to change a file it had just made, a 12B
/// model called `create` again, got back `presentation 2.html`, and told the
/// user the file was called `presentation.html`. The user's next message was
/// "you've told me the wrong file name."
///
/// So a clash is now a **refusal that names the alternative**. The wrong call
/// fails instead of quietly doing something else, which is the only version a
/// small model reliably notices. `availableURL` stays for attachments, where
/// a dropped file genuinely must not clobber an earlier one.
@MainActor
enum ChatFileWriter {
    // Files go in the *chat's* folder — see `ChatFiles` — so a conversation
    // and everything it produced can be deleted, browsed or carried around as
    // one thing. The writer is handed that directory rather than deciding it.

    /// Extensions the assistant may write.
    ///
    /// An allow-list, not a block-list. These are documents and data; nothing
    /// here is executable by double-clicking, which rules out the worst
    /// outcome of a model writing a file at the suggestion of a web page it
    /// just read.
    nonisolated static let allowedExtensions: Set<String> = [
        "md", "markdown", "txt", "json", "csv", "tsv", "yaml", "yml", "xml",
        "html", "css", "js", "ts", "py", "rb", "swift", "sh", "sql", "toml",
        "ini", "conf", "log", "srt", "vtt", "tex", "rtf",
    ]

    /// Largest file the assistant may write. Comfortably more than any reply,
    /// and a bound on a model that decides to repeat itself.
    private static let maximumBytes = 2 * 1024 * 1024

    /// What a write produced. Structured rather than a sentence, because the
    /// transcript renders the file itself — with a preview and somewhere to
    /// send it — and a success string would have to be parsed back apart to
    /// do that.
    enum Outcome {
        case written(url: URL, byteCount: Int)
        case failed(String)

        /// What the model is told.
        ///
        /// Two deliberate choices, both from watching this go wrong. The
        /// filename is stated twice, once as a fact and once as an
        /// instruction, because the model's own belief about what it called
        /// the file is what it otherwise reports. And there is no longer a
        /// "don't tell them the path" clause: it was read as "don't dwell on
        /// the name", and the name is the one thing the user needs.
        var modelDescription: String {
            switch self {
            case .written(let url, let byteCount):
                return """
                    OK: wrote \(url.lastPathComponent) (\(byteCount) bytes) in this chat's folder.
                    The file is called exactly “\(url.lastPathComponent)” — use that name when \
                    you tell the user about it. It's already shown to them in the conversation \
                    with buttons to open or save it, so don't repeat its contents back.
                    """
            case .failed(let message):
                return "ERROR: \(message)"
            }
        }
    }

    static func write(name rawName: String, contents: String, in directory: URL) -> Outcome {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("no filename was given.") }
        guard contents.utf8.count <= maximumBytes else {
            return .failed("that's larger than the \(maximumBytes / 1024 / 1024) MB limit for a written file.")
        }

        guard let target = resolve(name: trimmed, in: directory) else {
            return .failed(unusableMessage(for: trimmed))
        }

        // A clash means the model meant `update` — say so, rather than
        // inventing a name it will then misreport.
        guard !FileManager.default.fileExists(atPath: target.path) else {
            let existing = target.lastPathComponent
            return .failed(
                "“\(existing)” already exists in this chat's folder, so nothing was written. "
                    + "To change it: call read_file on “\(existing)”, then update_file with the "
                    + "complete new contents. To keep both: call create_file again with a "
                    + "different name.")
        }

        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
            return .written(url: target, byteCount: contents.utf8.count)
        } catch {
            return .failed("couldn't write the file: \(error.localizedDescription)")
        }
    }

    /// Resolves a name the model gave into a real path inside `root`.
    ///
    /// Once a chat can point at the user's own project folder, "no separators
    /// allowed" stops being reasonable — `src/main.swift` is an ordinary thing
    /// to ask for. So subpaths are allowed and *containment* becomes the thing
    /// that has to hold:
    ///
    /// - absolute paths and `~` are refused outright,
    /// - any `..` component is refused rather than resolved, because a model
    ///   writing `../../.ssh/authorized_keys` has made a decision worth
    ///   refusing visibly,
    /// - hidden components are refused, so it can't quietly edit dotfiles,
    /// - and the resolved path is checked against the resolved root **with
    ///   symlinks followed**, so a symlink inside the folder can't be used as
    ///   a door out of it.
    ///
    /// Returns nil for anything that fails, and the caller turns that into a
    /// message naming what's allowed.
    static func resolve(name rawName: String, in root: URL) -> URL? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        guard !trimmed.contains("\\"), !trimmed.contains(":") else { return nil }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty, components.count <= 8 else { return nil }
        for component in components {
            guard component != "..", component != ".", !component.hasPrefix(".") else { return nil }
            guard component.count <= 120 else { return nil }
            guard !component.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }) else { return nil }
        }

        guard let last = components.last else { return nil }
        let ext = URL(fileURLWithPath: last).pathExtension.lowercased()
        guard !ext.isEmpty, allowedExtensions.contains(ext) else { return nil }

        let candidate = root.appendingPathComponent(components.joined(separator: "/")).standardized
        // Compare with symlinks resolved on both sides. `resolvingSymlinksInPath`
        // resolves the components that exist, which is what matters: the escape
        // would be through an existing symlinked directory, not the new file.
        let resolvedRoot = root.resolvingSymlinksInPath().standardized.path
        let resolvedParent = candidate.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardized.path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/")
        else { return nil }
        return candidate
    }

    /// Back-compat shim for the bare-filename case, used where there is no
    /// root to resolve against (validation in tests and settings copy).
    nonisolated static func sanitise(_ raw: String) -> String? {
        guard !raw.contains("/"), !raw.contains("\\"), !raw.contains(":") else { return nil }
        guard raw != ".", raw != "..", !raw.hasPrefix(".") else { return nil }
        let url = URL(fileURLWithPath: raw)
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, allowedExtensions.contains(ext) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base.count <= 120 else { return nil }
        guard !base.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return "\(base).\(ext)"
    }

    /// `notes.md`, then `notes 2.md`, and so on.
    ///
    /// Shared with `ChatAttachments`, which has the same problem from the other
    /// direction: attaching the same file twice must not overwrite the first.
    nonisolated static func availableURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for suffix in 2...999 {
            let candidate = directory.appendingPathComponent("\(base) \(suffix).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString.prefix(6)).\(ext)")
    }

    // MARK: - Working with files already in the chat

    /// What's in the working directory.
    ///
    /// Walks subdirectories, because once a chat can be pointed at a real
    /// project a flat listing of the top level tells it almost nothing. Bounded
    /// hard, and skipping the directories that are always noise — a listing
    /// that wanders into `node_modules` would bury the answer and blow the
    /// context window doing it.
    static func list(in directory: URL) -> String {
        let skipped: Set<String> = [
            "node_modules", ".git", ".build", "build", "DerivedData", "dist",
            "Pods", "vendor", "__pycache__", ".venv", "venv", ".next", "target",
        ]
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return "Couldn't read this folder." }

        var rows: [String] = []
        var omitted = 0
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard rows.count < listLimit else { omitted += 1; continue }
            let relative = url.path.hasPrefix(directory.path + "/")
                ? String(url.path.dropFirst(directory.path.count + 1))
                : url.lastPathComponent
            let size = values?.fileSize ?? 0
            rows.append("- \(relative) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        }

        guard !rows.isEmpty else { return "This folder is empty." }
        var output = rows.sorted().joined(separator: "\n")
        if omitted > 0 { output += "\n…and \(omitted) more." }
        return "Files here:\n" + output
    }

    private static let listLimit = 200

    /// Reads one back, so the assistant can change a file rather than guess at
    /// what it wrote earlier — the transcript may well have been trimmed by
    /// then, and the user may have edited the file themselves since.
    static func read(name rawName: String, in directory: URL) -> String {
        guard let url = resolve(name: rawName, in: directory) else {
            return "ERROR: " + unusableMessage(for: rawName)
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "ERROR: there's no file called “\(name)” here.\n" + list(in: directory)
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "ERROR: “\(name)” isn't readable as text."
        }
        let capped = String(contents.prefix(readCharacterLimit))
        let truncated = contents.count > readCharacterLimit
            ? "\n\n…[truncated: the file is \(contents.count) characters]" : ""
        return "\(name):\n<<<\n\(capped)\n>>>\(truncated)"
    }

    /// Replaces a file that already exists in this chat.
    ///
    /// Separate from `write` on purpose. Overwriting is the one destructive
    /// thing in here, so it has to be a deliberate choice the model makes by
    /// name — an `overwrite: true` flag on the creation tool would get set by
    /// accident, and the first anyone knew would be the previous version
    /// being gone.
    static func update(name rawName: String, contents: String, in directory: URL) -> Outcome {
        guard let url = resolve(name: rawName, in: directory) else {
            return .failed(unusableMessage(for: rawName))
        }
        guard contents.utf8.count <= maximumBytes else {
            return .failed("that's larger than the \(maximumBytes / 1024 / 1024) MB limit.")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failed(
                "there's no file called “\(name)” here to update — use create_file to make a new one.")
        }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .written(url: url, byteCount: contents.utf8.count)
        } catch {
            return .failed("couldn't update the file: \(error.localizedDescription)")
        }
    }

    private static let readCharacterLimit = 40_000

    private static func unusableMessage(for name: String) -> String {
        "“\(name)” isn't a usable path. Use a name inside this folder like notes.md or "
            + "src/main.swift — no absolute paths, no “..”, no hidden files — and one of these "
            + "types: " + allowedExtensions.sorted().joined(separator: ", ") + "."
    }

    /// Deletes a file by moving it to the Trash.
    ///
    /// Trash, not unlink. A model deciding to remove something is exactly the
    /// case where the user needs an undo, and macOS already has one they know
    /// how to use. It also means "delete that file" costs little to get wrong,
    /// which is the difference between a useful tool and one nobody dares let
    /// near anything.
    static func delete(name rawName: String, in directory: URL) -> String {
        guard let url = resolve(name: rawName, in: directory) else {
            return "ERROR: " + unusableMessage(for: rawName)
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "ERROR: there's no file called “\(name)” here.\n" + list(in: directory)
        }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            return "ERROR: “\(name)” is a folder. This only removes files."
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return "Moved \(name) to the Trash. It can be put back from there if that was wrong."
        } catch {
            return "ERROR: couldn't remove “\(name)”: \(error.localizedDescription)"
        }
    }
}
