import SwiftUI

/// The right-hand side: either the thread, or an explanation of why chat can't
/// run right now.
///
/// The unavailable states are shown rather than hidden, and they name the
/// models that would work. Hiding a feature behind a silent capability check
/// teaches people nothing; this is the same call made for window vision.
struct ChatDetailRoot: View {
    @Bindable var shell: ChatShellModel
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            switch ChatAvailability.current(settings: state.settings) {
            case .ready:
                ChatThreadView(shell: shell)
            case .unavailable(let reason):
                ChatUnavailableView(reason: reason)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whether chat can run, and if not, why.
enum ChatAvailability {
    enum Reason {
        case engineDisabled
        case appleUnavailable(String)
        case modelNotCapable(String)
        case modelNotDownloaded(String)
    }

    case ready
    case unavailable(Reason)

    @MainActor
    static func current(settings: DictatorSettings) -> ChatAvailability {
        switch settings.llmEngine {
        case .none:
            return .unavailable(.engineDisabled)
        case .apple:
            // Apple runs chat without tools — see the `LLMChatStreaming`
            // extension on `AppleFoundationLLMService`. It used to be refused
            // outright, which also made every thread in the sidebar
            // unopenable, including the Assistant Mode ones that predate the
            // window. Reading your own conversation shouldn't depend on which
            // engine happens to be selected.
            guard AppleFoundationAvailability.isUsable else {
                return .unavailable(.appleUnavailable(
                    AppleFoundationAvailability.unavailableMessage
                        ?? "Apple Intelligence isn't available on this Mac."))
            }
            return .ready
        case .mlx:
            break
        }
        let id = settings.llmModelID
        guard let model = ModelCatalog.llm(id: id), model.chatCapable else {
            let name = ModelCatalog.llm(id: id)?.displayName ?? id
            return .unavailable(.modelNotCapable(name))
        }
        // A screenshot run loads no models, and the window it's there to
        // capture is the one a user with a downloaded model sees.
        guard ModelManager.shared.llmStates[id] == .ready || ScreenshotMode.isActive else {
            return .unavailable(.modelNotDownloaded(model.displayName))
        }
        return .ready
    }

    /// Models that would turn this on, best first. Used in the explanation so
    /// the user has somewhere to go rather than just a "no".
    @MainActor
    static var capableModelNames: [String] {
        ModelCatalog.llmModels
            .filter { $0.chatCapable && !$0.isLegacy }
            .map(\.displayName)
    }
}

private struct ChatUnavailableView: View {
    let reason: ChatAvailability.Reason
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open Settings…") {
                SettingsWindowController.shared.show()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var title: String {
        switch reason {
        case .engineDisabled: return "Chat needs a language model"
        case .appleUnavailable: return "Apple Intelligence isn't available"
        case .modelNotCapable: return "This model can't run chat"
        case .modelNotDownloaded: return "The model isn't downloaded yet"
        }
    }

    private var detail: String {
        let capable = ChatAvailability.capableModelNames
        let list = capable.joined(separator: ", ")
        switch reason {
        case .engineDisabled:
            return "Language model passes are switched off. Turn one on in Settings → Models, then pick one of: \(list)."
        case .appleUnavailable(let message):
            return "\(message) Turn it on in System Settings, or switch to MLX in Settings → Models and pick one of: \(list)."
        case .modelNotCapable(let name):
            return "\(name) runs your dictation just fine, but it hasn't been tested for chat and tool calling. Models that have: \(list)."
        case .modelNotDownloaded(let name):
            return "\(name) can run chat, but it isn't on this Mac yet. Download it in Settings → Models."
        }
    }
}
