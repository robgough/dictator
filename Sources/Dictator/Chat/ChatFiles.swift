import Foundation

/// Where a chat's files live.
///
/// One folder per conversation, under `<synced>/Chat Files/`. The chat is the
/// unit of work, so the files it produced — and, later, anything dropped into
/// it — belong to it: browsable in Finder, synced with everything else, and
/// removed together when the conversation is.
///
/// The folder name is fixed when the chat first needs one and never changes.
/// Deriving it live from the title would rename the folder whenever the title
/// did, which breaks every path already recorded in the transcript; and keying
/// it purely on the UUID would leave the user staring at
/// `3F2A9C1E-…` in Finder. A readable slug plus a short id gets both.
@MainActor
enum ChatFiles {
    static var root: URL {
        SyncedStorage.directory.appendingPathComponent("Chat Files", isDirectory: true)
    }

    /// The directory this chat works in: the folder the user chose, or the
    /// chat's own if they haven't chosen one.
    static func workingDirectory(for thread: ChatThread) throws -> (url: URL, folderName: String?) {
        if let path = thread.workingDirectoryPath {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { throw ChatFilesError.missingWorkingDirectory(path) }
            return (url, nil)
        }
        let own = try folder(for: thread)
        return (own.url, own.folderName)
    }

    /// True when the chat is working in its own folder rather than one the
    /// user chose. Only then does Dictator own the contents.
    static func ownsFolder(_ thread: ChatThread) -> Bool {
        thread.workingDirectoryPath == nil
    }

    /// The folder for a thread, creating it if needed.
    ///
    /// Returns the name it settled on so the caller can record it on the
    /// thread — the thread is the only durable place that mapping can live.
    static func folder(for thread: ChatThread) throws -> (url: URL, folderName: String) {
        let name = thread.filesFolderName ?? proposedFolderName(for: thread)
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, name)
    }

    /// A readable, unique folder name: the chat's title, plus enough of its id
    /// to guarantee two chats called "New chat" don't collide.
    private static func proposedFolderName(for thread: ChatThread) -> String {
        let slug = slugify(thread.title)
        let suffix = thread.id.uuidString.prefix(6).lowercased()
        return slug.isEmpty ? "chat-\(suffix)" : "\(slug)-\(suffix)"
    }

    private static func slugify(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = title.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
        let words = cleaned
            .split(separator: " ", omittingEmptySubsequences: true)
            .prefix(6)
            .joined(separator: "-")
        return String(words.prefix(60)).lowercased()
    }

    /// Files in a thread's *own* folder. Deliberately empty for a chat pointed
    /// at the user's directory — this feeds the delete confirmation, and
    /// offering to delete somebody's project folder is not a thing to do.
    static func files(in thread: ChatThread) -> [URL] {
        guard ownsFolder(thread), let name = thread.filesFolderName else { return [] }
        let url = root.appendingPathComponent(name, isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents ?? []
    }

    /// Removes a thread's folder and everything in it.
    ///
    /// Only ever called with the user's explicit agreement — see the delete
    /// confirmation in the sidebar. Tying file lifetime to the chat is only
    /// reasonable if the destructive half is visible.
    static func deleteFolder(for thread: ChatThread) {
        // Never a folder the user chose, whatever the caller thinks.
        guard ownsFolder(thread), let name = thread.filesFolderName else { return }
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }
}

enum ChatFilesError: LocalizedError {
    case missingWorkingDirectory(String)

    var errorDescription: String? {
        switch self {
        case .missingWorkingDirectory(let path):
            return "This chat's folder (\(path)) isn't there any more. Pick another one."
        }
    }
}
