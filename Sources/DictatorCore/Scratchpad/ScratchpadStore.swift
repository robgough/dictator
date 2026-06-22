import Foundation

/// Reads and writes the single Scratchpad note as plain-text Markdown
/// (`scratchpad.md`) in the user's synced folder — alongside settings.json,
/// vocabulary.json, history.json and conversations.json.
///
/// Stored as `.md` deliberately: v1 treats the contents as plain text, but the
/// file is already Markdown on disk so a later build can render it without any
/// migration. Living in the synced folder means that if the user has pointed
/// that at iCloud Drive (or Dropbox, …) the note follows them to their other
/// Macs — and now their iPhone — for free. Conflict handling is intentionally
/// simple — last write wins; the editor reloads from disk every time it opens.
///
/// Writes go through `NSFileCoordinator` + atomic replace, mirroring the
/// settings store, so a sync daemon mid-flight (or a second Dictator process)
/// can't observe a half-written file.
///
/// The caller passes the target `URL` explicitly rather than the store
/// resolving it internally: on macOS the synced folder comes from
/// `SyncedStorage`, while on iOS it comes from the user's security-scoped
/// `SharedFolderBookmark`. Keeping the URL out of the store lets the same code
/// serve both — `ScratchpadModel.bootstrap(customDirectory:)` owns resolution.
@MainActor
enum ScratchpadStore {
    static let filename = "scratchpad.md"

    /// Returns the note's contents, `""` when no file exists yet (a legitimate
    /// fresh state), or `nil` when the file exists but couldn't be read — e.g.
    /// an iCloud-evicted file while offline, or a coordination failure. Callers
    /// must treat `nil` as "contents unknown" and never save over the file.
    static func load(from url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var text: String?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            text = try? String(contentsOf: coordURL, encoding: .utf8)
        }
        if let coordError {
            NSLog("[Dictator] Scratchpad: read coordination failed for \(url.path): \(coordError)")
        }
        if text == nil {
            NSLog("[Dictator] Scratchpad: \(url.path) exists but couldn't be read; treating contents as unknown")
        }
        return text
    }

    static func save(_ text: String, to url: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { coordURL in
            do {
                try Data(text.utf8).write(to: coordURL, options: .atomic)
            } catch {
                NSLog("[Dictator] Scratchpad: couldn't write \(coordURL.path): \(error)")
            }
        }
        if let coordError {
            NSLog("[Dictator] Scratchpad: write coordination failed for \(url.path): \(coordError)")
        }
    }
}
