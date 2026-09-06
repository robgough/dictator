import AppKit
import AVFoundation
import SwiftUI

/// First-run sheet, shown once over the meetings window until
/// `MeetingsSettings.hasCompletedOnboarding` is set.
///
/// It exists because Dictator Meetings needs two grants Dictator never asked
/// for and cannot inherit: the microphone (your half of the call) and **System
/// Audio Recording** (their half). TCC keys grants by bundle identifier, so a
/// user who has happily dictated for a year still arrives here with neither —
/// and the system-audio bucket has no preflight API at all, so the only way to
/// ask is to attempt a tap and see (`AudioRecordingPermission.probe()`). Doing
/// that silently at the first record press means the prompt lands *after* the
/// meeting has started; asking here means the first recording just works.
///
/// The Parakeet download is offered here for the same reason: it's a hard
/// requirement for any transcription, it's a few hundred megabytes, and the
/// moment to start it is now rather than as a modal in the middle of a call.
/// Nothing on this sheet is mandatory — "Skip for now" leaves the existing
/// per-action gates in the recording flow to catch whatever's missing.
struct MeetingsOnboardingSheet: View {
    let onFinish: () -> Void

    @Environment(MeetingsAppState.self) private var state
    @State private var manager = ModelManager.shared
    @State private var micStatus = MicPermission.status()
    /// nil until the first probe finishes — the probe is what raises the
    /// system prompt, so it is never run unattended at launch.
    @State private var systemAudioGranted: Bool?
    @State private var probingSystemAudio = false

    private var parakeetID: String { state.settings.parakeetModelID }
    private var parakeetState: ModelDownloadState {
        manager.parakeetStates[parakeetID] ?? .unknown
    }
    private var parakeetReady: Bool { parakeetState == .ready }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Dictator Meetings")
                    .font(.title2.weight(.semibold))
                Text("Two permissions and one model, and you're set. Everything runs on this Mac unless you point it at a cloud provider yourself.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                row(
                    icon: "mic",
                    title: "Microphone",
                    detail: "Records your side of the call.",
                    done: micStatus == .authorized,
                    busy: false,
                    actionTitle: micStatus == .denied || micStatus == .restricted ? "Open Settings" : "Allow",
                    action: requestMic
                )
                row(
                    icon: "speaker.wave.2",
                    title: "System audio",
                    detail: "Records the other side — what comes out of your speakers.",
                    done: systemAudioGranted == true,
                    busy: probingSystemAudio,
                    actionTitle: systemAudioGranted == false ? "Open Settings" : "Allow",
                    action: requestSystemAudio
                )
                row(
                    icon: "waveform",
                    title: "Speech model",
                    detail: parakeetDetail,
                    done: parakeetReady,
                    busy: parakeetState.isBusy,
                    actionTitle: "Download",
                    action: downloadParakeet
                )
            }

            Text("You can change any of this later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Skip for now", action: onFinish)
                Button("Done", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            manager.refreshCachedStates()
        }
    }

    private var parakeetDetail: String {
        switch parakeetState {
        case .ready: return "Downloaded and ready."
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .preparingDownload: return "Starting download…"
        case .failed(let message): return "Download failed: \(message)"
        default: return "Transcribes both tracks on-device. About 600 MB."
        }
    }

    @ViewBuilder
    private func row(icon: String,
                     title: String,
                     detail: String,
                     done: Bool,
                     busy: Bool,
                     actionTitle: String,
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if !done {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: - Actions

    private func requestMic() {
        guard micStatus == .notDetermined else {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
            return
        }
        MicPermission.request { _ in
            Task { @MainActor in micStatus = MicPermission.status() }
        }
    }

    /// Attempting a tap IS the request — there's no preflight for this bucket
    /// (see `AudioRecordingPermission`), so the first probe raises the system
    /// prompt and the second tells us how the user answered.
    private func requestSystemAudio() {
        if systemAudioGranted == false {
            AudioRecordingPermission.openSystemSettings()
            return
        }
        probingSystemAudio = true
        Task {
            let status = await AudioRecordingPermission.probe()
            systemAudioGranted = (status == .granted)
            probingSystemAudio = false
        }
    }

    private func downloadParakeet() {
        manager.downloadParakeet(parakeetID, using: ParakeetServiceHolder.shared)
    }
}

private extension ModelDownloadState {
    var isBusy: Bool {
        switch self {
        case .downloading, .preparingDownload: return true
        default: return false
        }
    }
}
