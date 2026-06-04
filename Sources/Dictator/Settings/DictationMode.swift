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

    /// Spoken-cue substitution is split into five independent families so
    /// users can keep punctuation cues on while disabling, say, emoji
    /// insertion. Pre-modes installs had a single `spokenCuesEnabled`
    /// flag — that's read by the decoder and used as the default for any
    /// of these five fields that aren't present in the persisted blob.
    var punctuationCuesEnabled: Bool
    var numberCuesEnabled: Bool
    var timeCuesEnabled: Bool
    var currencyCuesEnabled: Bool
    var emojiCuesEnabled: Bool

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

    /// When true, after a successful paste the pipeline synthesises a
    /// Return key press. Useful for chat apps (Slack, iMessage, Discord)
    /// and search fields where Return submits — pair with `appBundleIDs`
    /// so it only fires in apps that treat Return as send. Off by
    /// default because in any multi-line editor (TextEdit, VS Code, an
    /// email body) Return is just an unwanted blank line.
    var pressReturnAfterPaste: Bool

    /// Whether dictations in this mode read the text surrounding the
    /// insertion point (via the existing Accessibility permission) and use
    /// it in two places: the formatter pass sees it so names and terminology
    /// match the document, and the delivery join adapts spacing /
    /// capitalisation / the trailing full stop to the exact caret position
    /// (`InsertionJoiner`). All on-device; the context is never stored. Off
    /// → both fall back to the context-free heuristics.
    var contextAwarenessEnabled: Bool

    // MARK: - Stable IDs for the built-ins

    /// Hard-coded UUID for the built-in Quick mode. Stable across launches so
    /// other code can reliably reference "the Quick mode" without a name lookup.
    static let quickID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Hard-coded UUID for the seed Write mode. Users can rename or delete it
    /// after creation, so existence isn't guaranteed — only the freshly-migrated
    /// or freshly-installed state has this id present.
    static let writeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - Codable

    /// Hand-rolled init so adding a new field doesn't break decode of every
    /// persisted blob that pre-dates it. Each property uses `decodeIfPresent`
    /// with a sensible default — missing keys fall through, unknown keys are
    /// ignored. Without this, Swift's synthesised init demands every key be
    /// present, and an older blob causes the entire settings decode to throw —
    /// which the outer `try?` swallows, settings fall back to defaults, and
    /// the next save silently overwrites the user's data on disk.
    enum CodingKeys: String, CodingKey {
        case id, name, isLocked, includeInCycle, appBundleIDs
        case punctuationCuesEnabled, numberCuesEnabled, timeCuesEnabled
        case currencyCuesEnabled, emojiCuesEnabled, vocabularyEnabled
        case formattingPassEnabled, grammarPassMode, grammarPassMaxEditFraction
        case structuralPassEnabled, structuralPassMinWords
        case formattingPromptAddendum, formattingPromptOverride
        case grammarPromptAddendum, grammarPromptOverride
        case structuralPromptAddendum, structuralPromptOverride
        case pressReturnAfterPaste, contextAwarenessEnabled
    }

    /// Side container for the legacy single `spokenCuesEnabled` toggle.
    /// Kept off the main CodingKeys enum so Swift's synthesised encoder
    /// doesn't try to write a property that no longer exists; we just
    /// peek at the field on decode and use its value as the default for
    /// the new sub-toggles.
    private enum LegacyCueKey: String, CodingKey {
        case spokenCuesEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` and `name` are the only fields where a missing value would
        // genuinely indicate a broken record; for those we still throw rather
        // than invent an identity.
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        // Everything else defaults to a sensible value if absent — matches the
        // shape of `DictationMode.write` so a half-shaped blob comes back as a
        // normally-behaved Write mode rather than failing to decode.
        self.isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        self.includeInCycle = try c.decodeIfPresent(Bool.self, forKey: .includeInCycle) ?? true
        self.appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        // The pre-split `spokenCuesEnabled` flag, if present in this blob,
        // seeds whatever new sub-toggles are absent. A user who'd turned
        // spoken cues off entirely shouldn't have them silently re-enabled
        // just because we added more knobs.
        let legacyCues = (try? decoder.container(keyedBy: LegacyCueKey.self)
            .decodeIfPresent(Bool.self, forKey: .spokenCuesEnabled)) ?? nil
        let cueDefault = legacyCues ?? true
        self.punctuationCuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .punctuationCuesEnabled) ?? cueDefault
        self.numberCuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .numberCuesEnabled) ?? cueDefault
        self.timeCuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .timeCuesEnabled) ?? cueDefault
        self.currencyCuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .currencyCuesEnabled) ?? cueDefault
        self.emojiCuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .emojiCuesEnabled) ?? cueDefault
        self.vocabularyEnabled = try c.decodeIfPresent(Bool.self, forKey: .vocabularyEnabled) ?? true
        self.formattingPassEnabled = try c.decodeIfPresent(Bool.self, forKey: .formattingPassEnabled) ?? true
        self.grammarPassMode = try c.decodeIfPresent(GrammarPassMode.self, forKey: .grammarPassMode) ?? .tighten
        self.grammarPassMaxEditFraction = try c.decodeIfPresent(Double.self, forKey: .grammarPassMaxEditFraction) ?? 0.15
        self.structuralPassEnabled = try c.decodeIfPresent(Bool.self, forKey: .structuralPassEnabled) ?? true
        self.structuralPassMinWords = try c.decodeIfPresent(Int.self, forKey: .structuralPassMinWords) ?? 30
        self.formattingPromptAddendum = try c.decodeIfPresent(String.self, forKey: .formattingPromptAddendum) ?? ""
        self.formattingPromptOverride = try c.decodeIfPresent(String.self, forKey: .formattingPromptOverride)
        self.grammarPromptAddendum = try c.decodeIfPresent(String.self, forKey: .grammarPromptAddendum) ?? ""
        self.grammarPromptOverride = try c.decodeIfPresent(String.self, forKey: .grammarPromptOverride)
        self.structuralPromptAddendum = try c.decodeIfPresent(String.self, forKey: .structuralPromptAddendum) ?? ""
        self.structuralPromptOverride = try c.decodeIfPresent(String.self, forKey: .structuralPromptOverride)
        self.pressReturnAfterPaste = try c.decodeIfPresent(Bool.self, forKey: .pressReturnAfterPaste) ?? false
        self.contextAwarenessEnabled = try c.decodeIfPresent(Bool.self, forKey: .contextAwarenessEnabled) ?? true
    }

    /// Memberwise init is no longer synthesised because we declared
    /// `init(from:)`. Restore it explicitly so call sites that build modes
    /// (seeds, settings UI) still compile.
    init(
        id: UUID,
        name: String,
        isLocked: Bool,
        includeInCycle: Bool,
        appBundleIDs: [String],
        punctuationCuesEnabled: Bool,
        numberCuesEnabled: Bool,
        timeCuesEnabled: Bool,
        currencyCuesEnabled: Bool,
        emojiCuesEnabled: Bool,
        vocabularyEnabled: Bool,
        formattingPassEnabled: Bool,
        grammarPassMode: GrammarPassMode,
        grammarPassMaxEditFraction: Double,
        structuralPassEnabled: Bool,
        structuralPassMinWords: Int,
        formattingPromptAddendum: String,
        formattingPromptOverride: String?,
        grammarPromptAddendum: String,
        grammarPromptOverride: String?,
        structuralPromptAddendum: String,
        structuralPromptOverride: String?,
        pressReturnAfterPaste: Bool = false,
        contextAwarenessEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.isLocked = isLocked
        self.includeInCycle = includeInCycle
        self.appBundleIDs = appBundleIDs
        self.punctuationCuesEnabled = punctuationCuesEnabled
        self.numberCuesEnabled = numberCuesEnabled
        self.timeCuesEnabled = timeCuesEnabled
        self.currencyCuesEnabled = currencyCuesEnabled
        self.emojiCuesEnabled = emojiCuesEnabled
        self.vocabularyEnabled = vocabularyEnabled
        self.formattingPassEnabled = formattingPassEnabled
        self.grammarPassMode = grammarPassMode
        self.grammarPassMaxEditFraction = grammarPassMaxEditFraction
        self.structuralPassEnabled = structuralPassEnabled
        self.structuralPassMinWords = structuralPassMinWords
        self.formattingPromptAddendum = formattingPromptAddendum
        self.formattingPromptOverride = formattingPromptOverride
        self.grammarPromptAddendum = grammarPromptAddendum
        self.grammarPromptOverride = grammarPromptOverride
        self.structuralPromptAddendum = structuralPromptAddendum
        self.structuralPromptOverride = structuralPromptOverride
        self.pressReturnAfterPaste = pressReturnAfterPaste
        self.contextAwarenessEnabled = contextAwarenessEnabled
    }

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
        punctuationCuesEnabled: true,
        numberCuesEnabled: true,
        timeCuesEnabled: true,
        currencyCuesEnabled: true,
        emojiCuesEnabled: true,
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
        punctuationCuesEnabled: true,
        numberCuesEnabled: true,
        timeCuesEnabled: true,
        currencyCuesEnabled: true,
        emojiCuesEnabled: true,
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
