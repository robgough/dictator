import Foundation

/// Central resolver for the user-visible "synced" folder. Everything that
/// might reasonably travel between a user's Macs lives in here:
///
/// - `settings.json` — the synced half of `DictatorSettings` (modes,
///   prompts, hotkey choices, paste/sounds, user name).
/// - `vocabulary.json` — the custom dictionary.
/// - `history.json` — recent dictations.
/// - `conversations.json` — Assistant Mode multi-turn threads.
///
/// The directory defaults to `~/Documents/Dictator/`. If the user has set a
/// custom path (Settings → General → Synced folder), it's stored in
/// `local-settings.json` (per-Mac) and read here on every URL resolution —
/// so a folder relocation is picked up by every store on the next read or
/// write, no in-memory caching to invalidate.
///
/// The custom path lives in the local file specifically because each Mac may
/// be configured differently (one Mac on iCloud Drive, another on Dropbox,
/// another using the default). Putting the path on the synced side would be
/// self-defeating.
enum SyncedStorage {
    /// Resolves the synced folder URL. Reads `AppState.shared.settings.syncedDirectoryPath`
    /// from the main actor — callers from background contexts should hop
    /// to main before calling.
    @MainActor
    static var directory: URL {
        let custom = AppState.shared.settings.syncedDirectoryPath
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultDirectory
    }

    /// Default location, `~/Documents/Dictator/`. User-visible in Finder
    /// under Documents; if that folder is in iCloud Drive (or any other
    /// sync provider) the contents sync automatically. `nonisolated` so
    /// the settings loader can use it before AppState is ready.
    nonisolated static var defaultDirectory: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents")
        return documents.appendingPathComponent("Dictator", isDirectory: true)
    }

    /// Build a file URL inside the synced folder. Creates the folder
    /// lazily on first request so callers don't have to remember.
    @MainActor
    static func fileURL(for filename: String) -> URL {
        ensureDirectory(at: directory)
        return directory.appendingPathComponent(filename)
    }

    /// Same as `fileURL(for:)` but for use during the early bootstrap path
    /// where AppState may not yet be initialised. Caller passes in the
    /// resolved directory explicitly.
    nonisolated static func fileURL(in directory: URL, filename: String) -> URL {
        ensureDirectory(at: directory)
        return directory.appendingPathComponent(filename)
    }

    /// One-time migration: if `filename` lives in the legacy App Support
    /// location and a copy doesn't already exist in the synced folder,
    /// copy it over. Idempotent — once the synced copy exists, subsequent
    /// calls are no-ops. Doesn't delete the source so a rollback to an
    /// older binary can still find the data.
    @MainActor
    static func migrateFromAppSupport(filename: String) {
        let target = fileURL(for: filename)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let source = supportDir
            .appendingPathComponent("Dictator", isDirectory: true)
            .appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            NSLog("[Dictator] Couldn't migrate \(filename) to synced folder: \(error)")
        }
    }

    /// Copies every known synced file from `old` to `new` when the user
    /// picks a different folder, so their data follows the picker action
    /// instead of leaving behind stranded copies in the old location.
    @MainActor
    static func relocateContents(from old: URL, to new: URL) {
        let filenames = ["settings.json", "vocabulary.json", "history.json", "conversations.json"]
        ensureDirectory(at: new)
        for name in filenames {
            let src = old.appendingPathComponent(name)
            let dst = new.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }

    private nonisolated static func ensureDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
