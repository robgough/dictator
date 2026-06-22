import SwiftUI
import UIKit

@main
struct DictatorIOSApp: App {
    /// Carries the active keyboard-extension hand-off, if any. Set
    /// when the app is opened via `dictator://keyboard?...`; cleared
    /// after the recording completes and the result has been written
    /// back to the shared App Group.
    @State private var keyboardRequest: KeyboardBridge.Request?

    /// Wire a UIKit application delegate alongside the SwiftUI App so
    /// background URLSession events (model downloads continuing while
    /// Dictator is suspended) get routed to the downloader's stored
    /// completion handler. SwiftUI's `App` doesn't expose
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`,
    /// so the only clean way to hook it is an `UIApplicationDelegateAdaptor`.
    @UIApplicationDelegateAdaptor(DictatorAppDelegate.self) private var appDelegate

    init() {
        // Defaults registered here so first-launch reads return the
        // expected "everything on" state rather than `false` for every
        // bool key. Keeps `@AppStorage` views and the view model's raw
        // `UserDefaults.bool(forKey:)` reads in agreement.
        DictatorIOSSettings.registerDefaults()

        // Screenshot-capture hook. The UI test harness sets this when
        // it wants to re-show the first-launch welcome sheet — flip
        // the persistent "onboarding done" flag back off so the sheet
        // re-presents on this launch. No-op in normal builds.
        if ProcessInfo.processInfo.environment["DICTATOR_RESET_ONBOARDING"] == "1"
            || CommandLine.arguments.contains("-DictatorResetOnboarding") {
            UserDefaults.standard.set(false, forKey: DictatorIOSSettings.onboardingCompletedKey)
        }
        // Mirror image of the reset hook. The UI test toggles this on
        // for every shot AFTER the welcome sheet so the persistent
        // flag doesn't stay stuck at false after the welcome capture.
        if ProcessInfo.processInfo.environment["DICTATOR_FORCE_ONBOARDING_DONE"] == "1"
            || CommandLine.arguments.contains("-DictatorForceOnboardingDone") {
            UserDefaults.standard.set(true, forKey: DictatorIOSSettings.onboardingCompletedKey)
        }

        // Resolve the user's shared-folder bookmark if they've opted
        // in. Done before VocabularyStore.bootstrap so the store loads
        // directly from the shared location (via iCloud Drive, Dropbox,
        // etc.) instead of the sandbox. Failure is silent here — the
        // Settings UI exposes the resolved/error state and lets the
        // user re-pick or disconnect; throwing in App init would just
        // crash launch with no recourse.
        let sharedFolder = (try? SharedFolderBookmark.resolve()) ?? nil

        // VocabularyStore is a singleton that loads from disk on bootstrap;
        // until that runs, `entries` is empty and substitution is a silent
        // no-op. Doing this at App init keeps it ahead of the first view
        // appearing — the ContentView's @State viewModel is constructed
        // lazily on first body evaluation, by which point the store has
        // already populated.
        VocabularyStore.shared.bootstrap(customDirectory: sharedFolder, legacyEntries: nil)
        UsageStatsStore.shared.bootstrap(customDirectory: sharedFolder)
        // Point the Scratchpad note at the same folder so it syncs with the
        // Mac (which writes scratchpad.md into its synced folder). Without a
        // shared folder it lives device-local in the sandbox; the Scratchpad
        // tab nudges the user to connect one. bootstrap() reloads from disk.
        ScratchpadModel.shared.bootstrap(customDirectory: sharedFolder)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(keyboardRequest: $keyboardRequest)
                // Cold-launch path: iOS hands the URL through
                // `onOpenURL` before the first render, so the view
                // model sees the request by the time it shows its
                // body.
                .onOpenURL { url in
                    if let parsed = Self.parseKeyboardURL(url) {
                        keyboardRequest = parsed
                    }
                }
        }
    }

    /// Parses `dictator://keyboard?mode=record&session=…` URLs.
    /// Other paths fall through to nil — they'll just open the app
    /// normally with no keyboard side effects.
    private static func parseKeyboardURL(_ url: URL) -> KeyboardBridge.Request? {
        guard url.scheme == "dictator", url.host == "keyboard" else { return nil }
        // Pull the staged request out of the shared container — the
        // URL itself only carries identifiers; the actual payload
        // (mode + surrounding text + session id) was written before
        // the keyboard opened the URL. This avoids URL length
        // limits for the assist path's potentially large input.
        return KeyboardBridge.peekRequest()
    }
}

/// UIKit-side delegate. Two responsibilities:
///   1. Touch `BackgroundModelDownloader.shared` at launch so the
///      background URLSession gets recreated and iOS replays any pending
///      delegate events from downloads that ran while we were suspended.
///   2. Route the system's
///      `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
///      callback into the downloader so it can fire the system handler
///      once it's finished consuming the replayed events. Without this,
///      iOS would kill the app's background snapshot before the OS-side
///      delivery completes.
final class DictatorAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Reattach to any in-flight downloads from a previous launch.
        // Cheap if there are none (an idempotent disk probe), and
        // critical when there are — the background URLSession needs to
        // exist with the right identifier before iOS replays the
        // delegate events for transfers that finished while we were
        // suspended.
        Task { @MainActor in
            BackgroundModelDownloader.shared.bootstrapOnLaunch()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Only one background session in this app — match by identifier
        // anyway so we don't accidentally swallow events for a future
        // session.
        guard identifier == BackgroundModelDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        // The system handler must be invoked on the main thread per
        // Apple's docs. The downloader's `handleEventsDelivered` already
        // hops to `@MainActor` before calling whatever it has stored, so
        // we wrap the OS-provided closure with a main-actor shim that
        // calls back on the main thread.
        Task { @MainActor in
            BackgroundModelDownloader.shared.setSystemBackgroundCompletionHandler {
                completionHandler()
            }
        }
    }
}
