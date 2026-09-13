import Foundation
import Sparkle

/// Decides whether this copy of the app is allowed to update *itself*.
///
/// Both Mac apps embed Sparkle and point it at an appcast (`SUFeedURL` in
/// project.yml). That is right for a build the release workflow produced and
/// wrong for every other build, because of how versions are stamped: the
/// release workflow passes `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` on
/// the `xcodebuild` line, and `CURRENT_PROJECT_VERSION` is the GitHub run
/// number. A build made any other way — ⌘B / ⌘R in Xcode, a CLI compile-check,
/// a screenshot run — keeps project.yml's literal `CURRENT_PROJECT_VERSION: 1`.
///
/// Sparkle compares `sparkle:version` (CFBundleVersion) against the running
/// bundle's, so a local build's build number of 1 is below every release that
/// has ever shipped. The updater therefore concludes the app is out of date
/// *always*, and with `SUAutomaticallyUpdate` on it downloads the release DMG
/// and swaps it in the next time the app quits. Three things then go wrong:
///
///   1. The local build under test is silently replaced by the released one,
///      so the change being tested disappears without a word.
///   2. The swap happens during a quit Sparkle triggers itself, which reads
///      from the outside as the app vanishing on its own — i.e. as a crash.
///   3. Release builds carry a different signing identity to local ones, so
///      the swap invalidates the app's TCC grants (Accessibility, Screen
///      Recording) and it starts prompting on every paste.
///
/// So: an unstamped build never starts its updater.
public enum UpdaterGate {
    /// The `CURRENT_PROJECT_VERSION` literal in project.yml — what a build
    /// carries when nothing overrode it on the `xcodebuild` line.
    private static let unstampedBuildNumber = "1"

    /// Whether the release workflow produced this bundle.
    ///
    /// Two independent signals, either of which is enough to disqualify a
    /// build. `DEBUG` catches the ordinary Xcode build; the build-number check
    /// also catches a *local Release* build, which is what the compile-check
    /// and screenshot scripts produce and which `DEBUG` alone would wave
    /// through. The run number is monotonic and long past 1, so a genuine
    /// release can never look unstamped.
    public static var isReleaseBuild: Bool {
        #if DEBUG
            return false
        #else
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            return build != unstampedBuildNumber
        #endif
    }

    /// Builds the app's updater controller, started only for a release build.
    ///
    /// The gate is `startingUpdater:` rather than a post-hoc
    /// `automaticallyChecksForUpdates = false` on purpose. That property is a
    /// *persisted user preference* (`SUEnableAutomaticChecks` in the app's
    /// defaults domain), and a local build shares its bundle ID — and so its
    /// defaults — with the installed release. Writing the preference from a
    /// local build would follow the user back to the released app and quietly
    /// turn off updates there for good. Declining to start the updater touches
    /// no preferences at all.
    ///
    /// An unstarted updater reports `canCheckForUpdates == false` for its
    /// lifetime, so the "Check for Updates…" buttons that bind to it disable
    /// themselves without needing to know why.
    @MainActor
    public static func makeUpdaterController() -> SPUStandardUpdaterController {
        SPUStandardUpdaterController(
            startingUpdater: isReleaseBuild,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
