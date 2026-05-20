import Foundation

/// A named bundle of dictation post-processing settings.
///
/// Each mode picks which of the three optional LLM passes run on a dictation
/// (formatter, grammar, structure) and carries its own prompt addendum/override
/// for each. The user picks a default mode from the menu bar; the active mode
/// can be cycled mid-recording with a key (default: Tab).
///
/// Two modes are seeded on first launch:
///
/// - **Quick** (`isLocked == true`): all passes off — raw transcript ships
///   through the spoken-cue substitution and the user's vocabulary, then out.
///   Locked because "no LLM" is the floor; editing prompts on it is moot, and
///   keeping it always-present anchors the cycle.
/// - **Write** (`isLocked == false`): all passes on, default prompts. Migrated
///   from the legacy top-level prompt/pass fields so existing customisation
///   isn't lost.
///
/// `appBundleIDs` lets a mode auto-activate when the focused app's bundle ID
/// matches. First mode in `settings.modes` whose `appBundleIDs` contains the
/// front app's identifier wins; otherwise we fall back to `defaultModeID`.
struct DictationMode: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// True for the built-in Quick mode. The UI hides delete/rename/prompt-edit
    /// affordances on locked modes so their identity is stable.
    var isLocked: Bool
    /// Whether the mid-recording cycle key flips through this mode. A user can
    /// keep an "Email" mode configured for app auto-activation without it
    /// showing up in the Tab rotation.
    var includeInCycle: Bool
    /// Bundle IDs of apps that should auto-pick this mode at recording start.
    /// Empty means "no app binding". First-match wins across modes — drag a
    /// mode higher in the list to give its bindings precedence.
    var appBundleIDs: [String]

    /// Whether the deterministic spoken-cue substitution runs ("comma" → ",",
    /// "fire emoji" → 🔥, etc.). Off makes the mode behave as a closer-to-raw
    /// transcript — useful when the user is dictating something where the
    /// words "comma" and "period" should appear literally.
    var spokenCuesEnabled: Bool
    /// Whether the user's vocabulary list (deterministic whole-word
    /// substitutions in `settings.vocabulary`) is applied in this mode. The
    /// list itself stays global — this is just an on/off per mode.
    var vocabularyEnabled: Bool

    var formattingPassEnabled: Bool
    var grammarPassMode: GrammarPassMode
    /// Applies only when `grammarPassMode == .tidy`. The `.tighten` mode uses
    /// its own permissive validator — see `Pipeline.maybeFixGrammar`.
    var grammarPassMaxEditFraction: Double
    var structuralPassEnabled: Bool
    var structuralPassMinWords: Int

    var formattingPromptAddendum: String
    var formattingPromptOverride: String?
    var grammarPromptAddendum: String
    var grammarPromptOverride: String?
    var structuralPromptAddendum: String
    var structuralPromptOverride: String?

    // MARK: - Stable IDs for the built-ins

    /// Hard-coded UUID for the built-in Quick mode. Stable across launches so
    /// other code can reliably reference "the Quick mode" without a name lookup.
    static let quickID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Hard-coded UUID for the seed Write mode. Users can rename or delete it
    /// after creation, so existence isn't guaranteed — only the freshly-migrated
    /// or freshly-installed state has this id present.
    static let writeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Effective prompts

    var effectiveFormattingPrompt: String {
        Self.combine(builtin: DictatorSettings.builtinFormattingPrompt,
                     override: formattingPromptOverride,
                     addendum: formattingPromptAddendum)
    }

    var effectiveGrammarPrompt: String {
        // Tidy vs tighten pick different built-ins; override (when set) still
        // replaces wholesale so users can pin a single custom prompt without
        // it silently swapping under them when they change the mode.
        let builtin: String
        switch grammarPassMode {
        case .off, .tidy:
            builtin = DictatorSettings.builtinGrammarPrompt
        case .tighten:
            builtin = DictatorSettings.builtinTightenPrompt
        }
        return Self.combine(builtin: builtin,
                            override: grammarPromptOverride,
                            addendum: grammarPromptAddendum)
    }

    var effectiveStructuralPrompt: String {
        Self.combine(builtin: DictatorSettings.builtinStructuralPrompt,
                     override: structuralPromptOverride,
                     addendum: structuralPromptAddendum)
    }

    private static func combine(builtin: String, override: String?, addendum: String) -> String {
        if let override { return override }
        let trimmed = addendum.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return builtin }
        return builtin + "\n\nADDITIONAL USER INSTRUCTIONS (apply alongside everything above):\n" + trimmed
    }

    // MARK: - Seeds

    /// The locked, no-LLM Quick mode. Always present in `settings.modes`.
    static let quick = DictationMode(
        id: quickID,
        name: "Quick",
        isLocked: true,
        includeInCycle: true,
        appBundleIDs: [],
        spokenCuesEnabled: true,
        vocabularyEnabled: true,
        formattingPassEnabled: false,
        grammarPassMode: .off,
        grammarPassMaxEditFraction: 0.15,
        structuralPassEnabled: false,
        structuralPassMinWords: 30,
        formattingPromptAddendum: "",
        formattingPromptOverride: nil,
        grammarPromptAddendum: "",
        grammarPromptOverride: nil,
        structuralPromptAddendum: "",
        structuralPromptOverride: nil
    )

    /// The default Write mode used for fresh installs. Existing installs get
    /// their legacy field values migrated into a Write mode via
    /// `DictationMode.write(seededFromLegacy:)` so customisation survives.
    static let write = DictationMode(
        id: writeID,
        name: "Write",
        isLocked: false,
        includeInCycle: true,
        appBundleIDs: [],
        spokenCuesEnabled: true,
        vocabularyEnabled: true,
        formattingPassEnabled: true,
        grammarPassMode: .tighten,
        grammarPassMaxEditFraction: 0.15,
        structuralPassEnabled: true,
        structuralPassMinWords: 30,
        formattingPromptAddendum: "",
        formattingPromptOverride: nil,
        grammarPromptAddendum: "",
        grammarPromptOverride: nil,
        structuralPromptAddendum: "",
        structuralPromptOverride: nil
    )
}
