import Foundation

/// Manages the iOS-only opt-in to a shared folder for vocabulary and
/// usage stats. The user picks a folder via `UIDocumentPicker` (or
/// SwiftUI's `.fileImporter`), iOS hands back a security-scoped URL,
/// and this helper persists it as a bookmark in `UserDefaults`. On
/// every app launch we resolve the bookmark, start access, and point
/// `VocabularyStore` / `UsageStatsStore` at the folder.
///
/// Why a bookmark rather than just storing the URL: a raw URL string
/// loses iOS's permission grant the moment the app is relaunched. The
/// bookmark encodes both the path and the security-scope grant; iOS
/// reissues the grant when we resolve it again. Without this dance,
/// the second-launch read of a Files.app-picked folder fails with
/// `NSCocoaErrorDomain code=257` (permission denied).
///
/// **iOS specifics**: `.withSecurityScope` is macOS-only; on iOS the
/// security scope is implicit in bookmarks created from a picker
/// callback. So we pass `[]` for create+resolve options here.
///
/// **Lifecycle**: `startAccessingSecurityScopedResource()` is balanced
/// against `stopAccessingSecurityScopedResource()`. We keep a single
/// active URL across the app's lifetime — there's no benefit to
/// stop/start churn while the app is running, and the system reclaims
/// the grant at process exit anyway.
@MainActor
enum SharedFolderBookmark {
    private static let key = "DictatorIOS.sharedFolderBookmark.v1"

    /// The currently-active scoped URL, if any. Held strongly so the
    /// matching `stopAccessing` is reachable when the user disconnects
    /// or picks a different folder.
    private static var activeScopedURL: URL?

    /// True when a bookmark is persisted. UI uses this to choose
    /// between "Choose folder…" and "Disconnect" affordances without
    /// having to round-trip through `resolve()` (which would start a
    /// security-scope access we don't actually need at render time).
    static var isConfigured: Bool {
        UserDefaults.standard.data(forKey: key) != nil
    }

    /// The resolved folder URL, if a bookmark is set AND it resolved
    /// successfully on launch. nil if no bookmark or if it went stale
    /// and we cleared it.
    static var activeURL: URL? { activeScopedURL }

    /// Display name for the configured folder — last path component.
    /// Falls back to the full path if for some reason that's empty.
    static var displayName: String? {
        guard let url = activeScopedURL else { return nil }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    /// Full path of the configured folder, formatted as a breadcrumb
    /// so the user can verify they picked the right place. The on-disk
    /// path for an iCloud Drive folder on iOS looks like
    /// `/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/...`
    /// which is meaningless to a user — we replace the iCloud Drive
    /// container prefix with the user-visible `iCloud Drive` label
    /// before splitting on slashes. Other Files.app providers
    /// (Dropbox, Google Drive, on-device) fall through to the raw
    /// path; that's still readable enough as a breadcrumb.
    static var displayPath: String? {
        guard let url = activeScopedURL else { return nil }
        let raw = url.path(percentEncoded: false)
        let iCloudPrefixes = [
            "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs",
            "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs"
        ]
        var friendly = raw
        for prefix in iCloudPrefixes where friendly.hasPrefix(prefix) {
            friendly = "iCloud Drive" + friendly.dropFirst(prefix.count)
            break
        }
        return friendly
            .split(separator: "/")
            .joined(separator: " › ")
    }

    /// Save the picked URL as a security-scoped bookmark and start
    /// accessing it for the rest of the session. Returns the resolved
    /// URL. Throws on bookmark creation failure (rare — usually means
    /// the URL wasn't security-scoped, i.e. didn't come from a picker).
    @discardableResult
    static func save(_ url: URL) throws -> URL {
        // The picker hands us an already-scoped URL but on iOS we
        // still have to bracket access to read its bookmark data.
        let needsStop = url.startAccessingSecurityScopedResource()
        defer {
            // Stop only the temporary access used to create the bookmark.
            // We re-start access via the bookmark resolution below so
            // the resolved URL is the one we hold long-term, not the
            // raw picker URL.
            if needsStop { url.stopAccessingSecurityScopedResource() }
        }
        let data = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: key)
        return try resolve() ?? url
    }

    /// Resolve the persisted bookmark and start accessing it. Returns
    /// nil if no bookmark is saved. If the bookmark is stale (folder
    /// moved or renamed) iOS still resolves it to its new location and
    /// we transparently rewrite the bookmark. If resolution fails
    /// entirely (folder deleted) we clear the persisted bookmark so
    /// the UI flips back to "Choose folder…".
    @discardableResult
    static func resolve() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // The folder is gone (deleted from iCloud Drive, signed
            // out, etc.). Clear so the UI re-prompts on next render.
            UserDefaults.standard.removeObject(forKey: key)
            activeScopedURL?.stopAccessingSecurityScopedResource()
            activeScopedURL = nil
            throw error
        }

        if isStale {
            // Bookmark survived but referred to a moved/renamed
            // location; iOS updated the URL for us. Persist the new
            // bookmark so future launches skip the staleness path.
            if let refreshed = try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(refreshed, forKey: key)
            }
        }

        // Swap the active scope: stop the previous one (if any) before
        // starting the new one. Balanced even when we're re-resolving
        // the same URL — start/stop on an already-active scoped URL is
        // a documented no-op pair on iOS.
        activeScopedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        activeScopedURL = url
        return url
    }

    /// Drop the bookmark and stop accessing the folder. Used when the
    /// user disconnects in Settings.
    static func clear() {
        activeScopedURL?.stopAccessingSecurityScopedResource()
        activeScopedURL = nil
        UserDefaults.standard.removeObject(forKey: key)
    }
}
