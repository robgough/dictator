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
/// toggle. The Meetings WindowGroup stays registered unconditionally
/// (SwiftUI scene builders can't take a runtime `if`); registration alone
/// exposes nothing without an entry point.
@MainActor
enum MeetingsFeature {
    /// Whether Meetings is actually available: the user has opted into the
    /// preview on this Mac AND a usable LLM exists to write the notes.
    /// Meetings without an LLM is just an audio recorder with a transcript —
    /// the notes/summary pass is the product — so a missing LLM disables
    /// the feature outright rather than silently degrading it.
    static var isEnabled: Bool {
        AppState.shared.settings.meetingsEnabled && llmRequirementMessage == nil
    }

    /// Nil when a usable LLM is configured; otherwise a user-facing
    /// explanation of what's missing, surfaced on the Settings → Meetings
    /// pane next to the (disabled) master toggle.
    static var llmRequirementMessage: String? {
        let settings = AppState.shared.settings
        switch settings.llmEngine {
        case .none:
            return "Meetings needs an on-device LLM to write its notes and summaries, and the LLM is currently set to None. Pick one under Settings → Models → Formatting."
        case .apple:
            if AppleFoundationAvailability.isUsable { return nil }
            let reason = AppleFoundationAvailability.unavailableMessage ?? "Apple's foundation model is unavailable on this Mac."
            return "Meetings needs a working LLM to write its notes and summaries. \(reason)"
        case .mlx:
            if ModelManager.shared.llmStates[settings.llmModelID] == .ready { return nil }
            return "Meetings needs an on-device LLM to write its notes and summaries, and the selected model isn't downloaded on this Mac. Download it under Settings → Models → Formatting."
        }
    }
}
