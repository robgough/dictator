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
    /// Whether the user has opted into the Meetings preview on this Mac.
    static var isEnabled: Bool {
        AppState.shared.settings.meetingsEnabled
    }
}
