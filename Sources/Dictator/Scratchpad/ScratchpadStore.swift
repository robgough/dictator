import Foundation

/// Reads and writes the single Scratchpad note as plain-text Markdown
/// (`scratchpad.md`) in the user's synced folder — alongside settings.json,
/// vocabulary.json, history.json and conversations.json.
///
/// Stored as `.md` deliberately: v1 treats the contents as plain text, but the
/// file is already Markdown on disk so a later build can render it without any
/// migration. Living in the synced folder means that if the user has pointed
/// that at iCloud Drive (or Dropbox, …) the note follows them to their other
/// Macs for free. Conflict handling is intentionally simple — last write wins;
/// `ScratchpadController` reloads from disk every time the panel opens.
///
/// Writes go through `NSFileCoordinator` + atomic replace, mirroring the
/// settings store, so a sync daemon mid-flight (or a second Dictator process)
/// can't observe a half-written file.
@MainActor
enum ScratchpadStore {
    static let filename = "scratchpad.md"

    static func load() -> String {
        let url = SyncedStorage.fileURL(for: filename)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var text = ""
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            text = (try? String(contentsOf: coordURL, encoding: .utf8)) ?? ""
        }
        if let coordError {
            NSLog("[Dictator] Scratchpad: read coordination failed for \(url.path): \(coordError)")
        }
        return text
    }

    static func save(_ text: String) {
        let url = SyncedStorage.fileURL(for: filename)
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
