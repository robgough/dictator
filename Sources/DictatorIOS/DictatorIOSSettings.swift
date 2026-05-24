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
            selectedModelKey: "parakeet-tdt-0.6b-v3",
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
