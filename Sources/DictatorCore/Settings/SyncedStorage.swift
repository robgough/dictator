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
#if canImport(AppKit)
    /// Resolves the synced folder URL. Reads `AppState.shared.settings.syncedDirectoryPath`
    /// from the main actor — callers from background contexts should hop
    /// to main before calling.
    ///
    /// macOS-only: the synced-folder picker (`Settings → General → Synced
    /// folder`) lives behind `AppState`, which is itself macOS-only. iOS
    /// always uses `defaultDirectory`; when iOS grows a custom-folder
    /// picker the platform conditional comes off.
    @MainActor
    static var directory: URL {
        let custom = AppState.shared.settings.syncedDirectoryPath
        if let custom, !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultDirectory
    }
#endif

    /// Default location, `~/Documents/Dictator/`. User-visible in Finder
    /// under Documents; if that folder is in iCloud Drive (or any other
    /// sync provider) the contents sync automatically. `nonisolated` so
    /// the settings loader can use it before AppState is ready.
    nonisolated static var defaultDirectory: URL {
        // `homeDirectoryForCurrentUser` is macOS-only; `NSHomeDirectory()`
        // works on both platforms and returns the sandbox home on iOS.
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents")
        return documents.appendingPathComponent("Dictator", isDirectory: true)
    }

#if canImport(AppKit)
    /// Build a file URL inside the synced folder. Creates the folder
    /// lazily on first request so callers don't have to remember.
    @MainActor
    static func fileURL(for filename: String) -> URL {
        ensureDirectory(at: directory)
        return directory.appendingPathComponent(filename)
    }

    /// Whether the resolved synced folder lives inside iCloud Drive.
    /// Used by Stats to phrase the "totals add up across every Mac"
    /// footer concretely instead of conditionally — the answer is
    /// knowable, so the UI shouldn't ask the user to guess.
    ///
    /// Two checks, OR'd:
    ///   1. `URLResourceKey.isUbiquitousItemKey` — the canonical Apple
    ///      API. Returns true for files inside the user's iCloud
    ///      Drive area.
    ///   2. Path-prefix check against `~/Library/Mobile Documents/com~apple~CloudDocs/`,
    ///      after `resolvingSymlinksInPath`. Catches the "Desktop &
    ///      Documents Folders" iCloud setting on macOS, which moves
    ///      the user's real `~/Documents` into that container and
    ///      leaves a symlink behind — the URL we read off the user's
    ///      preference is the symlink path, so the resource-value
    ///      check would miss it without the symlink resolution.
    @MainActor
    static var isInICloudDrive: Bool {
        let url = directory
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        if values?.isUbiquitousItem == true {
            return true
        }
        let realPath = url.resolvingSymlinksInPath().path
        return realPath.contains("/Library/Mobile Documents/com~apple~CloudDocs/")
    }
#endif

    /// Same as `fileURL(for:)` but for use during the early bootstrap path
    /// where AppState may not yet be initialised. Caller passes in the
    /// resolved directory explicitly.
    nonisolated static func fileURL(in directory: URL, filename: String) -> URL {
        ensureDirectory(at: directory)
        return directory.appendingPathComponent(filename)
    }

#if canImport(AppKit)
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

    /// One-time cleanup of stranded `.previous` backups from an earlier
    /// version of the store. The atomic-rename write guarantees readers
    /// never see a half-written file, and decode-failure recovery now
    /// preserves bytes under `<filename>.recovered-<timestamp>.json`, so
    /// the rolling `.previous` slot is just visible clutter. Idempotent:
    /// no-ops on a freshly-installed setup.
    @MainActor
    static func cleanupLegacyBackups() {
        let names = ["settings.json", "vocabulary.json", "history.json", "conversations.json"]
        let dir = directory
        for name in names {
            let url = dir.appendingPathComponent("\(name).previous")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
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
#endif

    private nonisolated static func ensureDirectory(at url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
