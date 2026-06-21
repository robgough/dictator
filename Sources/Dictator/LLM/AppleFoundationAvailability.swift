import Foundation
import SwiftUI
import FoundationModels

/// Lightweight wrapper over `SystemLanguageModel.default.availability` for the
/// settings / onboarding / catalog code that just needs a yes/no answer or a
/// UI-renderable snapshot. The concrete service still throws typed errors so
/// the HUD can show a useful reason; these helpers are for the UI affordances
/// that surface availability state.
@MainActor
enum AppleFoundationAvailability {
    /// True when the OS will actually serve a request — device is eligible,
    /// Apple Intelligence is on, model is downloaded.
    static var isUsable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Smallest on-device context window we'll let power Meetings. As of
    /// macOS 27 (verified by probing the framework) third-party apps only get
    /// Apple's ~3B "Core" model with a fixed 4096-token window — the larger
    /// on-device model (AFM 3 Core Advanced, ~20B) is NOT exposed via
    /// `SystemLanguageModel`, and the big cloud model is PCC. So today this
    /// gate is always false and Apple is blocked for Meetings (the 4K model
    /// drifts and runs out of room on a full transcript, like the small MLX
    /// models). It's kept as a forward-compat guard: if a future build ever
    /// hands apps a bigger on-device window, Meetings auto-enable for Apple.
    /// Sits comfortably above 4096 and above the meeting chunker's ~6K-token
    /// window + prompt/reply overhead. Tune against the logged value.
    static let meetingsMinContextSize = 16_384

    /// The on-device model's context window in tokens, or nil when the model
    /// isn't available at all. macOS 27+ reports the real size; 26.x backstops
    /// to 4096. Logged once so the actual per-machine value is visible (the
    /// big-model window isn't documented) and the threshold can be tuned.
    static var contextSize: Int? {
        guard isUsable else { return nil }
        let size = SystemLanguageModel.default.contextSize
        if !didLogContextSize {
            didLogContextSize = true
            NSLog("[Dictator] Apple on-device model contextSize=\(size) tokens (meetings need ≥\(meetingsMinContextSize))")
        }
        return size
    }
    private static var didLogContextSize = false

    /// True when the on-device model is the larger variant capable of meeting
    /// notes — judged by its context window clearing `meetingsMinContextSize`.
    /// Meetings only accept Apple in this case; see `MeetingsFeature`.
    static var isMeetingsCapable: Bool {
        guard let size = contextSize else { return false }
        return size >= meetingsMinContextSize
    }

    /// One-line, honest description of the on-device model's context window
    /// and what it means for Meetings. Apple exposes only the ~3B "Core"
    /// model (4K context) to third-party apps; macOS 27's larger on-device
    /// model (AFM 3 Core Advanced, ~20B) and the cloud models aren't reachable
    /// through `SystemLanguageModel`, verified by probing the framework. So we
    /// don't imply a tier the user can switch to — we state the window and the
    /// Meetings consequence. Phrased off `contextSize` so it flips
    /// automatically if Apple ever raises the window we're handed. Nil when
    /// the model isn't available.
    static var contextSummary: String? {
        guard let ctx = contextSize else { return nil }
        let tokens = "\(ctx.formatted()) tokens"
        if ctx >= meetingsMinContextSize {
            return "On-device context window: \(tokens) — large enough for Meetings."
        }
        return "On-device context window: \(tokens). Fine for dictation and Assistant, but too small for Meetings — macOS 27's larger on-device model isn't available to third-party apps."
    }

    /// Human-readable explanation when the engine is not usable. Surfaced in the
    /// Settings + Onboarding views right under the engine picker.
    static var unavailableMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is off — enable it in System Settings → Apple Intelligence & Siri."
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence. Pick a different LLM."
            case .modelNotReady:
                return "Apple's foundation model is still downloading. Wait a few minutes, then try again."
            @unknown default:
                return "Apple Foundation model is unavailable on this Mac right now."
            }
        }
    }

    /// Snapshot of the availability state suited for SwiftUI rendering. Polled
    /// from the Settings + Onboarding panes so the row reflects live state
    /// (the user toggling Apple Intelligence on/off in System Settings doesn't
    /// otherwise nudge the SwiftUI tree).
    enum Reading: Equatable {
        case unknown
        case ready
        case appleIntelligenceOff
        case deviceIneligible
        case downloading
        case otherUnavailable(String)

        @MainActor
        static func current() -> Reading {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .deviceNotEligible:           return .deviceIneligible
                case .modelNotReady:               return .downloading
                @unknown default:                  return .otherUnavailable(String(describing: reason))
                }
            }
        }

        var iconName: String {
            switch self {
            case .unknown: return "circle.dashed"
            case .ready: return "checkmark.seal.fill"
            case .appleIntelligenceOff: return "exclamationmark.triangle.fill"
            case .deviceIneligible: return "xmark.octagon.fill"
            case .downloading: return "arrow.down.circle"
            case .otherUnavailable: return "questionmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .ready: return .green
            case .appleIntelligenceOff, .downloading: return .orange
            case .deviceIneligible, .otherUnavailable: return .red
            case .unknown: return .secondary
            }
        }

        var headline: String {
            switch self {
            case .unknown: return "Checking availability…"
            case .ready: return "Ready"
            case .appleIntelligenceOff: return "Apple Intelligence is off"
            case .deviceIneligible: return "This Mac is not eligible"
            case .downloading: return "Model is downloading"
            case .otherUnavailable: return "Unavailable"
            }
        }

        var detail: String {
            switch self {
            case .unknown:
                return "Querying SystemLanguageModel for its current state."
            case .ready:
                return "Apple Intelligence is enabled and the on-device model is loaded. Dictator will route all LLM passes through it."
            case .appleIntelligenceOff:
                return "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri, or switch to MLX (or None) above."
            case .deviceIneligible:
                return "This Mac doesn't support Apple Intelligence. Switch to MLX (or None) above."
            case .downloading:
                return "macOS is still downloading the foundation model in the background. Once it finishes you'll see Ready here. In the meantime, dictations that need an LLM will fail with a clear message in the HUD — switch to MLX (or None) above if you'd rather not wait."
            case .otherUnavailable(let reason):
                return "Apple Foundation Model is unavailable: \(reason). Switch to MLX (or None) above."
            }
        }

        private static var secondary: Color { Color.secondary }
    }
}
