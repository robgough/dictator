import SwiftUI

@main
struct DictatorIOSApp: App {
    /// Carries the active keyboard-extension hand-off, if any. Set
    /// when the app is opened via `dictator://keyboard?...`; cleared
    /// after the recording completes and the result has been written
    /// back to the shared App Group.
    @State private var keyboardRequest: KeyboardBridge.Request?

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

        // VocabularyStore is a singleton that loads from disk on bootstrap;
        // until that runs, `entries` is empty and substitution is a silent
        // no-op. Doing this at App init keeps it ahead of the first view
        // appearing — the ContentView's @State viewModel is constructed
        // lazily on first body evaluation, by which point the store has
        // already populated.
        VocabularyStore.shared.bootstrap(customDirectory: nil, legacyEntries: nil)
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
