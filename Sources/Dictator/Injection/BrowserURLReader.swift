import Foundation
import AppKit
import ApplicationServices

/// Reads the URL of the page in the frontmost browser window, so a mode can
/// bind itself to a *site* rather than just an app.
///
/// Binding to "Chrome" is close to useless — Chrome is Gmail, Linear, a
/// Google Doc and a YouTube video, and those want completely different
/// dictation treatments. The app binding stays for native apps; this is what
/// makes the browser case work.
///
/// Two routes, because the browsers disagree:
/// - **Safari (and anything WebKit-shaped)** puts the URL on the focused
///   window's `AXDocument`. One attribute read, no traversal.
/// - **Chromium browsers** (Chrome, Edge, Brave, Arc, Vivaldi, Opera) don't,
///   but their content area is an `AXWebArea` carrying an `AXURL`. Finding it
///   means a bounded walk of the window's subtree.
///
/// Every read is guarded: this runs at hotkey-press time, on the path that
/// already has form for stalling on main-thread work (see the mic-start
/// investigation), so it is skipped entirely unless a mode actually has a
/// website binding, the messaging timeout is short, and the traversal is
/// capped in both depth and node count.
enum BrowserURLReader {

    /// Bundle IDs worth asking. Anything not in here returns nil immediately
    /// rather than walking the UI tree of an app that has no URL to give.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser",     // Arc
        "company.thebrowser.dia",         // Dia
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.mozilla.firefox",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS",             // Orca
        "io.github.zen-browser.zen",
    ]

    /// Depth and breadth caps for the Chromium walk. The web area sits four to
    /// six levels down in practice; eight gives headroom without ever letting
    /// a pathological tree turn this into a visible pause.
    private static let maxDepth = 8
    private static let maxNodes = 400

    /// Per-call ceiling on AX round-trips, matching `AXContextReader`'s.
    private static let messagingTimeout: Float = 0.15

    static func isBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    /// The frontmost browser's current URL, or nil when the front app isn't a
    /// browser, Accessibility isn't granted, or nothing readable was found.
    ///
    /// Safe to call from any thread — the AX API is Mach IPC — but callers
    /// should still prefer a detached task, since "safe" isn't "fast".
    static func currentURL(bundleID: String?, pid: pid_t) -> String? {
        guard isBrowser(bundleID: bundleID), AXIsProcessTrusted() else { return nil }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowValue = windowRef else { return nil }
        let window = windowValue as! AXUIElement

        // Safari's route: the window itself carries the document URL.
        if let document = stringAttribute(window, kAXDocumentAttribute as String),
           let normalized = normalize(document) {
            return normalized
        }

        // Chromium's route: find the web area and read its AXURL.
        var visited = 0
        if let found = findWebAreaURL(in: window, depth: 0, visited: &visited) {
            return found
        }
        return nil
    }

    /// Whether `url` satisfies a user-written pattern.
    ///
    /// Patterns are deliberately not regexes — a website binding is something
    /// people paste a URL into, and a substring test on the normalized URL
    /// does the obvious thing for everything they'd type: "gmail.com",
    /// "github.com/dictator", "docs.google.com/spreadsheets". A leading "*."
    /// is tolerated (and ignored) because people write it out of habit.
    static func matches(url: String, pattern: String) -> Bool {
        var needle = pattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return false }
        for prefix in ["*.", "https://", "http://", "www."] where needle.hasPrefix(prefix) {
            needle = String(needle.dropFirst(prefix.count))
        }
        guard !needle.isEmpty else { return false }
        return url.contains(needle)
    }

    /// Lowercased, scheme- and "www."-stripped form that `matches` compares
    /// against, so a pattern works whether the user pasted the full URL or
    /// just typed the domain.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        // A bare "about:blank" or an empty new tab is not a site binding.
        guard !value.isEmpty, !value.hasPrefix("about:"), !value.hasPrefix("chrome://") else { return nil }
        return value
    }

    // MARK: - Traversal

    private static func findWebAreaURL(in element: AXUIElement, depth: Int, visited: inout Int) -> String? {
        guard depth < maxDepth, visited < maxNodes else { return nil }
        visited += 1

        if stringAttribute(element, kAXRoleAttribute as String) == "AXWebArea" {
            // AXURL comes back as an NSURL, not a string, on every browser
            // that implements it.
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef) == .success {
                if let url = urlRef as? URL, let normalized = normalize(url.absoluteString) {
                    return normalized
                }
                if let text = urlRef as? String, let normalized = normalize(text) {
                    return normalized
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findWebAreaURL(in: child, depth: depth + 1, visited: &visited) {
                return found
            }
            if visited >= maxNodes { return nil }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }
}
