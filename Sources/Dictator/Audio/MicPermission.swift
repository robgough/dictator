import AVFoundation

/// Thin wrapper around AVCaptureDevice's audio-authorization API. The Settings
/// UI uses this both to display live mic permission state and to actively
/// request access — the request call is what makes Dictator appear in
/// `System Settings → Privacy & Security → Microphone` in the first place.
///
/// Without an explicit request, macOS lazily prompts the first time
/// AVAudioEngine.start() is called (i.e. the first dictation), which means
/// the user only sees Dictator in the Settings list after they've already
/// tried — and possibly failed — to dictate.
enum MicPermission {
    /// Snapshot of the current authorization state. Polled by the Settings
    /// row so the UI updates when the user grants/revokes from System Settings.
    static func status() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Triggers the macOS permission prompt. Only meaningful when status is
    /// `.notDetermined`; for any other state the OS no-ops and invokes the
    /// completion with the current decision. `completion` fires on an
    /// unspecified queue, so callers that touch the main actor must hop.
    static func request(completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}
