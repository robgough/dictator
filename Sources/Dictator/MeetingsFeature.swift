import Foundation

/// Compile-time gate for the in-progress macOS Meetings feature.
///
/// Enabled in Debug builds for ongoing development; disabled in Release
/// builds so the feature stays out of user-facing Sparkle-distributed
/// releases until it's ready. Every Meetings entry point in the macOS
/// app — the menu bar entries, the Settings tab, the WindowGroup
/// registration, the `dictator://meetings` URL handler — is gated on
/// this constant (via `#if DEBUG` blocks at the syntax level, since
/// SwiftUI scene builders can't take a runtime `if`).
///
/// To temporarily enable in a Release build (e.g. a self-hosted dev
/// archive, or a TestFlight-style internal test), add
/// `MEETINGS_ENABLED` to the project's `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
/// in `project.yml` and re-run `./gen`. The flag stays compile-time so
/// the meetings UI doesn't even reach the bound view hierarchy on a
/// shipped Release; the underlying types still compile into the binary
/// (they live in the same target) but are unreachable.
///
/// When Meetings is ready to ship for real, flip the `#if` here to
/// always-true and delete the gated `#if DEBUG || MEETINGS_ENABLED`
/// blocks across the codebase in one sweep.
enum MeetingsFeature {
    /// Runtime accessor for non-scene contexts (e.g. URL handler
    /// switches, AppState callback wiring). Scene builders use the
    /// `#if` directly because SwiftUI's `SceneBuilder` doesn't accept
    /// a runtime `if`.
    static let isEnabled: Bool = {
        #if DEBUG || MEETINGS_ENABLED
        return true
        #else
        return false
        #endif
    }()
}
