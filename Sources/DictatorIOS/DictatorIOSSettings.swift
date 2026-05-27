import Foundation

/// Single source of truth for the iOS prototype's UserDefaults keys.
/// Centralised so the `@AppStorage` views in `SettingsView` and the
/// raw `UserDefaults.bool(forKey:)` reads in `RecordingViewModel` can't
/// drift apart on a typo.
///
/// Defaults are registered in `DictatorIOSApp.init()` via
/// `UserDefaults.standard.register(defaults:)` so first-launch reads
/// return the registered default rather than `false`.
enum DictatorIOSSettings {
    // Each toggle gates one family of substitutions inside
    // `SpokenCues.Options`. Defaults match the macOS app: everything on.
    static let cuePunctuationKey = "DictatorIOS.cues.punctuation"
    static let cueNumbersKey     = "DictatorIOS.cues.numbers"
    static let cueTimesKey       = "DictatorIOS.cues.times"
    static let cueCurrencyKey    = "DictatorIOS.cues.currency"
    static let cueEmojisKey      = "DictatorIOS.cues.emojis"

    /// Gates the optional Apple Foundation Models post-transcription
    /// cleanup pass. Defaults to ON when the device supports Apple
    /// Intelligence (the cleanup is genuinely useful for filler-heavy
    /// dictation and the cost is near-zero on capable hardware), OFF
    /// otherwise. `register(defaults:)` only fills in un-set keys, so
    /// any user who explicitly toggled it off keeps their preference.
    static let foundationCleanupKey = "DictatorIOS.foundationCleanupEnabled"

    /// Selected Parakeet model ID. Mirrors `ParakeetService.version(forID:)`
    /// — currently `"parakeet-tdt-0.6b-v3"` (default, latest) or
    /// `"parakeet-tdt-0.6b-v2"` (older, slightly smaller). Persists the
    /// user's pick across launches; first launch falls back to v3 via
    /// `registerDefaults()`.
    static let selectedModelKey = "DictatorIOS.selectedModelID"

    /// True once the user has either dismissed the "enable keyboard"
    /// onboarding card on the main view or actually used the keyboard
    /// (the host receives a `dictator://keyboard?...` URL). Hides the
    /// card thereafter so the main view stays uncluttered.
    static let keyboardOnboardingDismissedKey = "DictatorIOS.keyboardOnboardingDismissed"

    /// True once the user has either completed every step of the
    /// first-launch onboarding sheet (mic → model → keyboard install →
    /// Open Access) or chosen "Skip for now". One-and-done: the sheet
    /// supersedes the older scattered cards (which remain available as
    /// fallback re-prompts) and never re-presents once this flag flips.
    static let onboardingCompletedKey = "DictatorIOS.onboardingCompleted"

    /// True once the user has explicitly confirmed their model choice
    /// in the first-launch walkthrough's picker step. Persisted via
    /// `@AppStorage` rather than `@State` so a kill-and-relaunch
    /// mid-onboarding doesn't ask the user to re-pick a variant they
    /// already chose (and possibly already started downloading).
    static let modelChoiceConfirmedKey = "DictatorIOS.modelChoiceConfirmed"

    /// Best-guess default Parakeet variant based on the device's
    /// preferred language. English-locale users get v2 (English-only)
    /// — it's slightly tighter on English accuracy because the model
    /// isn't splitting capacity across other European languages.
    /// Everyone else gets v3 (multilingual). The user can still flip
    /// either way from the onboarding picker or settings — this only
    /// decides what we recommend / pre-select.
    @MainActor
    static func recommendedModelID() -> String {
        // `Locale.preferredLanguages` returns BCP-47 tags like "en-GB"
        // / "en-US" / "fr-FR" / "de-DE". Prefix-match on the 2-letter
        // language code; the region doesn't matter for our split.
        let preferred = Locale.preferredLanguages.first ?? "en"
        let langCode = String(preferred.split(separator: "-").first ?? "en").lowercased()
        return langCode == "en" ? "parakeet-tdt-0.6b-v2" : "parakeet-tdt-0.6b-v3"
    }

    /// Register first-launch defaults so `UserDefaults.bool(forKey:)`
    /// reads return the intended value for un-set keys. Called once
    /// from `DictatorIOSApp.init()` (main actor). Built as a static
    /// func rather than a `static let` to keep Swift 6's Sendable
    /// check from flagging the dictionary's `Any` value type as
    /// not-concurrency-safe — this rebuilds the dict on each call,
    /// but it's only called once.
    @MainActor
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            cuePunctuationKey: true,
            cueNumbersKey: true,
            cueTimesKey: true,
            cueCurrencyKey: true,
            cueEmojisKey: true,
            // Default reflects device capability — capable users get
            // the feature on, others see the toggle hidden so the
            // stored value is moot.
            foundationCleanupKey: AppleFoundationCleanup.isAvailable,
            // Locale-aware first-launch default: English locales get
            // v2, everyone else gets v3. The picker in the onboarding
            // sheet still lets the user flip either way.
            selectedModelKey: recommendedModelID(),
        ])
    }

    /// Composed `SpokenCues.Options` for non-view callers. Settings views
    /// should use `@AppStorage(...)` on the individual keys above so
    /// toggles propagate live.
    static var cueOptions: SpokenCues.Options {
        let defaults = UserDefaults.standard
        return SpokenCues.Options(
            punctuation: defaults.bool(forKey: cuePunctuationKey),
            numbers: defaults.bool(forKey: cueNumbersKey),
            times: defaults.bool(forKey: cueTimesKey),
            currency: defaults.bool(forKey: cueCurrencyKey),
            emojis: defaults.bool(forKey: cueEmojisKey)
        )
    }
}
