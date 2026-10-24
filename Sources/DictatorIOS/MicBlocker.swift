import SwiftUI
import UIKit

/// Why a mic button can't record yet. Instead of a caption permanently
/// beside the button, pressing it explains — and offers the fix.
enum MicBlocker: Identifiable, Equatable {
    case askPermission
    case permissionDenied
    case needsModel
    case downloading(percent: Int)
    case checking

    var id: String {
        switch self {
        case .askPermission: "ask"
        case .permissionDenied: "denied"
        case .needsModel: "model"
        case .downloading: "downloading"
        case .checking: "checking"
        }
    }

    @MainActor
    static func current(_ viewModel: RecordingViewModel) -> MicBlocker? {
        switch viewModel.permission {
        case .undetermined: return .askPermission
        case .denied: return .permissionDenied
        default: break
        }
        switch viewModel.modelDiskStatus {
        case .downloaded: return nil
        case .downloading(let progress, _): return .downloading(percent: Int(progress * 100))
        case .checking: return .checking
        case .notDownloaded, .paused: return .needsModel
        @unknown default: return .needsModel
        }
    }
}

extension View {
    /// Shows the explanation for a blocked mic press.
    func micBlockerAlert(_ blocker: Binding<MicBlocker?>, viewModel: RecordingViewModel) -> some View {
        modifier(MicBlockerAlert(blocker: blocker, viewModel: viewModel))
    }
}

/// Call from a mic button's blocked press: asks for permission directly
/// when it has never been asked, otherwise raises the alert.
@MainActor
func handleBlockedMic(_ viewModel: RecordingViewModel, showing: Binding<MicBlocker?>) {
    guard let blocker = MicBlocker.current(viewModel) else { return }
    switch blocker {
    case .askPermission:
        Task { await viewModel.requestPermissionIfNeeded() }
    case .checking:
        break
    default:
        showing.wrappedValue = blocker
    }
}

private struct MicBlockerAlert: ViewModifier {
    @Binding var blocker: MicBlocker?
    let viewModel: RecordingViewModel

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(
            get: { blocker != nil },
            set: { if !$0 { blocker = nil } }
        )) {
            switch blocker {
            case .permissionDenied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Not Now", role: .cancel) {}
            case .needsModel:
                Button("Download") { Task { await viewModel.downloadModel() } }
                Button("Not Now", role: .cancel) {}
            default:
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch blocker {
        case .permissionDenied: "Microphone access is off"
        case .needsModel: "Download the speech model"
        case .downloading: "Still downloading"
        default: ""
        }
    }

    private var message: String {
        switch blocker {
        case .permissionDenied:
            "Dictator needs the microphone to hear you. Turn it on in Settings › Dictator."
        case .needsModel:
            "Dictator transcribes on this device, so it needs its speech model first. It's a one-time download."
        case .downloading(let percent):
            "The speech model is \(percent)% downloaded. The mic works as soon as it finishes."
        default:
            ""
        }
    }
}
