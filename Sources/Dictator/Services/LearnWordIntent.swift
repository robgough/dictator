import AppIntents
import Foundation

/// Modern App Intents counterpart to `LearnWordProvider`. The intent
/// surfaces "Learn Word in Dictator" in Spotlight, Shortcuts.app, and Siri
/// — the same destinations every other App Intent on the system reaches.
/// The Services menu specifically is covered by the NSServices path; App
/// Intents only reach Services indirectly via a user-built Shortcut with
/// "Use as a Quick Action" toggled on.
///
/// Both entry points terminate in `LearnWordPanelController.present(prefill:)`
/// — the popup, the duplicate-detection, and the save path are shared.
struct LearnWordIntent: AppIntent {
    static let title: LocalizedStringResource = "Learn Word in Dictator"
    static let description = IntentDescription(
        "Add a custom spelling rule to Dictator's dictionary. Pass the word you want Dictator to learn; a popup confirms the rule.",
        categoryName: "Dictionary"
    )

    /// Bring Dictator forward so the popup is visible without the user
    /// having to hunt for the menu-bar app afterwards.
    static let openAppWhenRun = true

    @Parameter(title: "Word",
               description: "The word or phrase to learn. From Shortcuts you'd usually pipe in 'Selected Text' or the previous step's output.")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        LearnWordPanelController.shared.present(prefill: text)
        return .result()
    }
}

/// Registers `LearnWordIntent` as a user-facing App Shortcut. Without
/// this, the intent is invocable from Shortcuts.app but doesn't appear
/// in Spotlight or Siri as a phrase.
struct DictatorAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LearnWordIntent(),
            phrases: [
                "Learn word in \(.applicationName)",
                "Add to \(.applicationName) dictionary"
            ],
            shortTitle: "Learn Word",
            systemImageName: "character.book.closed"
        )
    }
}
