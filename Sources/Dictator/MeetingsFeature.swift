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
    /// preview on this Mac AND the one LLM that writes acceptable meeting
    /// notes is selected and downloaded. Meetings without that LLM is just
    /// an audio recorder with a transcript — the notes/summary pass is the
    /// product — so an unmet requirement disables the feature outright
    /// rather than silently degrading it.
    static var isEnabled: Bool {
        AppState.shared.settings.meetingsEnabled && llmRequirementMessage == nil
    }

    /// Nil when the required meetings LLM is selected and on disk;
    /// otherwise a user-facing explanation of what's missing, surfaced on
    /// the Settings → Meetings pane next to the (disabled) master toggle.
    /// Meetings requires one specific model
    /// (`ModelCatalog.meetingsRequiredLLMID`) — see the catalog constant
    /// for the rationale — so any other engine/model combination, however
    /// healthy, reads as "not configured for meetings".
    static var llmRequirementMessage: String? {
        let settings = AppState.shared.settings
        let required = ModelCatalog.meetingsRequiredLLMName
        guard settings.meetingsLLMSatisfied else {
            return "Meetings needs \(required) to write its notes — it's the only model that handles a full meeting transcript reliably. Select it under Settings → Models → Formatting."
        }
        guard ModelManager.shared.llmStates[settings.llmModelID] == .ready else {
            return "Meetings needs \(required), which isn't downloaded on this Mac yet. Download it under Settings → Models → Formatting."
        }
        return nil
    }
}
