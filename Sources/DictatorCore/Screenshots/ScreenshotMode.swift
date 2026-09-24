import Foundation

/// Developer-only "screenshot mode" — internal tooling, never a user-facing
/// feature, and completely inert unless `DICTATOR_SCREENSHOT` is set in the
/// environment.
///
/// It exists so the marketing site can carry screenshots of the *real* UI
/// filled with obviously-fictional data, taken by the app rendering its own
/// windows (no Screen Recording grant needed, no real data on screen). The
/// capture instance runs alongside the user's installed copies and must never
/// read or write their settings, history, meetings, models or Keychain items.
///
/// Contract (see `scripts/mac-screenshots.sh`):
///
///   - `DICTATOR_SCREENSHOT=<shot>` — which capture to perform.
///     Dictator: `modes`, `assistant-draft`, `hud-styles`, `journal`, `chat`,
///     `demo-history`.
///     Dictator Meetings: `live-recording`, `notes`, `coach`.
///   - `DICTATOR_SCREENSHOT_OUT=<path.png>` — where to write the PNG.
///   - `DICTATOR_SCREENSHOT_DATA=<dir>` — a throwaway data root. EVERY
///     persistence path resolves under it: the synced folder
///     (`SyncedStorage`), the per-Mac `Application Support/Dictator` tree
///     (`AppSupportPaths` — models, local settings, history, mic log, the LLM
///     socket, meetings), and `UserDefaults` (`AppDefaults`). Unset falls back
///     to a per-process temporary directory rather than the real locations, so
///     a mis-invocation still can't touch the user's data.
///
/// Every hook in normal code is one `ScreenshotMode.isActive` check (or a read
/// of one of the overrides below).
enum ScreenshotMode {
    private static let environment = ProcessInfo.processInfo.environment

    /// Which capture this process was launched to perform. nil — the normal
    /// case — means screenshot mode is off and nothing below is consulted.
    static let shot: String? = {
        guard let raw = environment["DICTATOR_SCREENSHOT"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    static var isActive: Bool { shot != nil }

    /// Destination PNG. nil when unset — the runner then logs instead of writing.
    static let outputPath: String? = {
        guard isActive, let raw = environment["DICTATOR_SCREENSHOT_OUT"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    /// The throwaway data root every persistence path is rebased onto.
    static let dataRoot: URL? = {
        guard isActive else { return nil }
        let raw = environment["DICTATOR_SCREENSHOT_DATA"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = raw.isEmpty
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("DictatorScreenshots-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            : URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Stands in for `~/Library/Application Support` (see `AppSupportPaths`).
    static var applicationSupportOverride: URL? {
        guard let dataRoot else { return nil }
        let url = dataRoot.appendingPathComponent("Application Support", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stands in for the user-visible synced folder (`SyncedStorage`).
    static var syncedDirectoryOverride: URL? {
        guard let dataRoot else { return nil }
        let url = dataRoot.appendingPathComponent("Synced", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// `UserDefaults.standard`, except in screenshot mode where it's a throwaway
/// suite — an unsigned capture build shares the installed app's bundle id, so
/// `.standard` would be the user's real preference domain.
enum AppDefaults {
    nonisolated(unsafe) static let shared: UserDefaults = {
        guard ScreenshotMode.isActive else { return .standard }
        let suite = "net.robgough.Dictator.screenshots.\(ProcessInfo.processInfo.processIdentifier)"
        return UserDefaults(suiteName: suite) ?? .standard
    }()
}

/// The one resolver for the per-Mac `Application Support` tree. Models, the
/// local settings files, the mic log, the sound-cue cache, the LLM socket and
/// the meeting audio folders all hang off this, so screenshot mode only has to
/// redirect it in one place.
enum AppSupportPaths {
    /// `~/Library/Application Support` (or the screenshot-mode stand-in).
    nonisolated static var base: URL {
        if let override = ScreenshotMode.applicationSupportOverride { return override }
        let fm = FileManager.default
        return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// `~/Library/Application Support/Dictator` — shared by both Mac apps.
    /// Not created here; callers that write create what they need.
    nonisolated static var dictator: URL {
        base.appendingPathComponent("Dictator", isDirectory: true)
    }
}
