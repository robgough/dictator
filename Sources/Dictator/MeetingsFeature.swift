import Foundation

/// Runtime gate for the Meetings feature, which ships as an early preview.
///
/// Formerly a compile-time gate (`#if DEBUG || MEETINGS_ENABLED`) that kept
/// the feature out of Release builds entirely. Now that Meetings is being
/// previewed with real users it compiles into every build and is gated at
/// runtime instead: `settings.meetingsEnabled` defaults to OFF, and the
/// menu bar entries plus the `dictator://meetings` deep link check it
/// before exposing anything. The Settings → Meetings tab is the one place
/// that's always reachable — it hosts the preview notice and the opt-in
/// toggle. The Meetings window stays registered unconditionally
/// (SwiftUI scene builders can't take a runtime `if`); registration alone
/// exposes nothing without an entry point.
@MainActor
enum MeetingsFeature {
    /// Whether Meetings is actually available: the user has opted into the
    /// preview on this Mac AND there's *some* working LLM to write notes
    /// with. Meetings without any LLM is just an audio recorder with a
    /// transcript — the notes/summary pass is the product — so a missing
    /// note-writer disables the feature outright. Which model is the user's
    /// call now (see `llmQualityNote`); only "no usable LLM at all" blocks.
    static var isEnabled: Bool {
        AppState.shared.settings.meetingsEnabled && llmRequirementMessage == nil
    }

    /// Hard requirement gate. Nil when a note-writing LLM is configured and
    /// actually usable; otherwise a user-facing explanation of what's
    /// missing, surfaced on the Settings → Meetings pane next to the
    /// (disabled) master toggle and on the record/import gate. Meetings used
    /// to require one specific model; now any engine qualifies as long as it
    /// can run — the soft "this isn't the recommended model" nudge lives in
    /// `llmQualityNote`.
    static var llmRequirementMessage: String? {
        let settings = AppState.shared.settings
        let recommended = ModelCatalog.meetingsRecommendedLLMName
        switch settings.llmEngine {
        case .none:
            return "Meetings need a formatting model to write notes — turn one on under Settings → Models → Formatting."
        case .apple:
            guard AppleFoundationAvailability.isUsable else {
                return AppleFoundationAvailability.unavailableMessage
                    ?? "Apple's on-device model isn't available right now — pick another model under Settings → Models → Formatting."
            }
            // Apps only get Apple's ~3B / 4K on-device model; macOS 27's
            // larger on-device model and the cloud models aren't reachable via
            // SystemLanguageModel (verified by probing the framework), and the
            // 4K model drifts / runs out of room on a full transcript. So
            // Apple is blocked for meetings today. The contextSize gate is
            // kept so this auto-enables if Apple ever hands apps a bigger
            // on-device window.
            guard AppleFoundationAvailability.isMeetingsCapable else {
                return "Apple's on-device model is too small to write reliable meeting notes (apps only get its 4K-token model). Switch to \(recommended) or another capable model under Settings → Models → Formatting."
            }
            return nil
        case .mlx:
            // Hard quality floor: the smallest models produce notes that
            // aren't worth keeping (`LLMModel.meetingsCapable`).
            guard let model = ModelCatalog.llm(id: settings.llmModelID), model.meetingsCapable else {
                let name = ModelCatalog.llm(id: settings.llmModelID)?.displayName ?? settings.llmModelID
                return "\(name) is too small to write reliable meeting notes. Choose \(recommended) or another capable model under Settings → Models → Formatting."
            }
            guard ModelManager.shared.llmStates[settings.llmModelID] == .ready else {
                return "Meetings need \(model.displayName) downloaded first — get it under Settings → Models → Formatting."
            }
            return nil
        }
    }

    /// Non-blocking quality nudge for a *capable but not recommended* MLX
    /// model. Nil when there's a hard requirement to fix first, on the
    /// recommended model, or on the Apple engine (which only gets this far as
    /// the larger model — a first-class option we don't nag about). Meetings
    /// still run — this is shown *alongside* the feature, never instead of
    /// it. Surfaced on Settings → Meetings and the per-meeting notes CTA.
    static var llmQualityNote: String? {
        guard llmRequirementMessage == nil else { return nil }
        let settings = AppState.shared.settings
        guard settings.llmEngine == .mlx, !settings.meetingsUsingRecommendedLLM else { return nil }
        let recommended = ModelCatalog.meetingsRecommendedLLMName
        return "Meeting notes are tuned for \(recommended). The model you've selected will still write them, but quality may drop on long meetings — attribution slips or invented structure. Switch under Settings → Models → Formatting."
    }
}
