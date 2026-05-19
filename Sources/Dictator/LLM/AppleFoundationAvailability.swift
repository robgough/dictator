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
