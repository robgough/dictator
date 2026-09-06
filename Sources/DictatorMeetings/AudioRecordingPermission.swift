import Foundation
import AudioToolbox
import AppKit

/// Probe + system-settings deep link for the **system audio recording** TCC
/// bucket (Settings → Privacy & Security → System Audio Recording, gated by
/// `NSAudioCaptureUsageDescription`). This is the permission Apple added
/// alongside the CoreAudio Process Tap API (`AudioHardwareCreateProcessTap`)
/// in macOS 14.4. There is no public preflight API for this bucket — the
/// established pattern (see insidegui/AudioCap) is to attempt to create a
/// tap and treat a hard "not authorized" error as a denial signal. The
/// first failed attempt also triggers the system prompt the user expects.
///
/// Shape mirrors the old `ScreenRecordingPermission` enum so callers don't
/// shift. The old SCK-shaped permission story is gone — Dictator no longer
/// uses ScreenCaptureKit for meeting capture.
enum AudioRecordingPermission {
    enum Status: Equatable {
        case granted
        case notGranted(reason: String)
    }

    /// Try to create (and immediately destroy) a stereo-global process tap
    /// that excludes our own PID. If macOS hands back a tap object, we have
    /// the grant. Common failure shapes:
    ///   - `kAudioHardwareIllegalOperationError` (0x77686174 = 'what')
    ///     before the user has responded to the system prompt.
    ///   - `kAudio_NotPermittedError` (-1) after explicit denial.
    /// We don't try to distinguish them — either way the recorder can't run,
    /// and the user gets the same deep-link UX to fix it.
    static func probe() async -> Status {
        await Task.detached(priority: .userInitiated) {
            // Empty exclude list — we just need ANY tap creation to
            // succeed to know the TCC grant is in place. The Swift
            // refinement of `initStereoGlobalTapButExcludeProcesses:`
            // takes `[AudioObjectID]` (the underlying Obj-C is an
            // NSArray<NSNumber*> of process object IDs).
            let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            desc.name = "Dictator audio recording permission probe"
            desc.uuid = UUID()
            desc.muteBehavior = .unmuted

            var tapID: AUAudioObjectID = AudioObjectID(kAudioObjectUnknown)
            let err = AudioHardwareCreateProcessTap(desc, &tapID)
            if err == noErr, tapID != AudioObjectID(kAudioObjectUnknown) {
                _ = AudioHardwareDestroyProcessTap(tapID)
                return Status.granted
            }
            return Status.notGranted(reason: "Process tap creation failed (OSStatus \(err))")
        }.value
    }

    /// Open the System Audio Recording pane in System Settings. The deep
    /// link uses the `Privacy_AudioCapture` anchor introduced in macOS 14.4
    /// alongside the API. If Apple ever moves the anchor we still land in
    /// Privacy & Security at the root, which is recoverable for the user.
    @MainActor
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
