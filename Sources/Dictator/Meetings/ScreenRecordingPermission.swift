import Foundation
import ScreenCaptureKit
import AppKit

/// Thin wrapper around the screen-recording TCC probe. SCK has no
/// `requestPermission()` analogue to AVCaptureDevice — the only way to find
/// out is to call `SCShareableContent.current` and observe the failure.
/// That call also triggers the system prompt the very first time, which is
/// the same UX the user gets via the standard mic flow.
enum ScreenRecordingPermission {
    enum Status: Equatable {
        case granted
        case notGranted(reason: String)
    }

    /// Issue the probe. Returns once SCK responds — caller should treat this
    /// as a one-shot check; TCC requires an app restart after grant, so a
    /// `notGranted` response leaves nothing useful to retry inside this
    /// process lifetime.
    static func probe() async -> Status {
        do {
            _ = try await SCShareableContent.current
            return .granted
        } catch {
            return .notGranted(reason: error.localizedDescription)
        }
    }

    /// Open System Settings to the Screen Recording pane. Best-effort —
    /// macOS occasionally falls back to the privacy root if the deep link
    /// changes between releases.
    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
