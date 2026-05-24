import SwiftUI

@main
struct DictatorIOSApp: App {
    init() {
        // Defaults registered here so first-launch reads return the
        // expected "everything on" state rather than `false` for every
        // bool key. Keeps `@AppStorage` views and the view model's raw
        // `UserDefaults.bool(forKey:)` reads in agreement.
        DictatorIOSSettings.registerDefaults()

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
            ContentView()
        }
    }
}
