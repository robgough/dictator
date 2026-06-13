import CoreGraphics
import AppKit

/// Probe + request + settings deep-link for the **Screen Recording** TCC bucket
/// (Settings → Privacy & Security → Screen Recording). Unlike mic / calendar /
/// system-audio, screen recording has no Info.plist usage-description key — it's
/// a purely system-managed grant — so the sanctioned API surface is the two
/// CoreGraphics calls below.
///
/// Note the macOS quirk callers must design around: `CGRequestScreenCaptureAccess`
/// shows the system prompt and returns the *current* (pre-grant) status, and the
/// new grant typically only takes effect after the app is relaunched. So the
/// first meeting after enabling capture won't capture; the next one (post
/// re-grant / relaunch) will. The toggle's footer says as much.
enum ScreenRecordingPermission {
    /// True if Dictator already holds the grant. Cheap, no prompt.
    static func hasAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Show the system prompt if not yet granted. Returns the current grant
    /// state (usually still false on the very first call — see the type note).
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
