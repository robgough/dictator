import Foundation

/// A named bundle of dictation post-processing settings.
///
/// Each mode carries an ordered list of `steps` (its LLM pipeline) plus the
/// deterministic pre-processing toggles, context, and delivery options. The user
/// picks a default mode from the menu bar; the active mode can be cycled
/// mid-recording with a key (default: Tab).
///
/// Fresh installs seed a curated set: **Quick** (`isLocked == true`, no steps —
/// raw transcript through cues + vocabulary, the floor), **Standard** (one
/// Format step), **Polished** (Format + Grammar), and **Formal** (Format +
/// Tighten). Users can add more from the "+" gallery. Modes saved before the
/// step model are migrated on decode (see `LegacyPassKeys` / `derivedSteps`).
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

    /// The ordered LLM pipeline for this mode. Each step transforms the previous
    /// step's output; a mode with no steps ships the raw transcript (after the
    /// deterministic cue/vocabulary passes) straight out, like Quick. This is
    /// the source of truth. Blobs saved before the step model carried fixed
    /// `formattingPassEnabled` / `grammarPassMode` / per-pass prompt fields
    /// instead — the decoder reads those via `LegacyPassKeys` and synthesises
    /// `steps` from them (`derivedSteps`); they are never encoded again.
    var steps: [DictationStep]

    /// When true, after a successful paste the pipeline synthesises a
    /// Return key press. Useful for chat apps (Slack, iMessage, Discord)
    /// and search fields where Return submits — pair with `appBundleIDs`
    /// so it only fires in apps that treat Return as send. Off by
    /// default because in any multi-line editor (TextEdit, VS Code, an
    /// email body) Return is just an unwanted blank line.
    var pressReturnAfterPaste: Bool

    /// When true, every delivered dictation ends with a single trailing space —
    /// even when context-aware joining would otherwise omit it (the caret sits
    /// at the end of a terminal or chat line with nothing after it). Lets you
    /// fire off back-to-back dictations without manually typing a leading space
    /// between them. Off by default; independent of `pressReturnAfterPaste`.
    var appendTrailingSpace: Bool

    /// Whether dictations in this mode read the text surrounding the
    /// insertion point (via the existing Accessibility permission) and use
    /// it in two places: the formatter pass sees it so names and terminology
    /// match the document, and the delivery join adapts spacing /
    /// capitalisation / the trailing full stop to the exact caret position
    /// (`InsertionJoiner`). All on-device; the context is never stored. Off
    /// → both fall back to the context-free heuristics.
    var contextAwarenessEnabled: Bool

    /// Whether dictations in this mode additionally take a single on-device
    /// snapshot of the focused window (via Screen Recording) and read the
    /// proper nouns / distinctive terms visible in it with Apple's on-device
    /// vision model, merging them into the same spelling-reference terms the
    /// Accessibility read produces. Reaches names that sit *outside* the text
    /// field — and apps that don't expose their text to Accessibility at all.
    /// Off by default; needs macOS 27 + Screen Recording permission. The image
    /// never leaves the Mac and is never stored. Independent of
    /// `contextAwarenessEnabled` — either, both, or neither can be on.
    var windowVisionContextEnabled: Bool

    // MARK: - Stable IDs for the built-ins

    /// Hard-coded UUID for the built-in Quick mode. Stable across launches so
    /// other code can reliably reference "the Quick mode" without a name lookup.
    static let quickID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Hard-coded UUID for the seed Write mode. Users can rename or delete it
    /// after creation, so existence isn't guaranteed — only the freshly-migrated
    /// or freshly-installed state has this id present.
    static let writeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    /// Stable IDs for the curated step-based seed modes. Fresh installs get all
    /// three; they can also be re-added later from the "+" gallery, which mints
    /// fresh ids so the user can keep several.
    static let standardID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let polishedID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let formalID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

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
        case steps
        case pressReturnAfterPaste, contextAwarenessEnabled, appendTrailingSpace
        case windowVisionContextEnabled
    }

    /// Side container for the legacy single `spokenCuesEnabled` toggle.
    /// Kept off the main CodingKeys enum so Swift's synthesised encoder
    /// doesn't try to write a property that no longer exists; we just
    /// peek at the field on decode and use its value as the default for
    /// the new sub-toggles.
    private enum LegacyCueKey: String, CodingKey {
        case spokenCuesEnabled
    }

    /// Side container for the pre-step fixed-pass fields. Read only during
    /// decode of a blob that has no `steps` key, to synthesise the step list;
    /// never encoded (Swift's synthesised encoder only writes `CodingKeys`).
    /// Delete once no installed copy could still hold the pre-step shape.
    private enum LegacyPassKeys: String, CodingKey {
        case formattingPassEnabled, grammarPassMode, grammarPassMaxEditFraction
        case structuralPassEnabled, structuralPassMinWords
        case formattingPromptAddendum, formattingPromptOverride
        case grammarPromptAddendum, grammarPromptOverride
        case structuralPromptAddendum, structuralPromptOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` and `name` are the only fields where a missing value would
        // genuinely indicate a broken record; for those we still throw rather
        // than invent an identity.
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        // Everything else defaults to a sensible value if absent, so a
        // half-shaped blob comes back as a normally-behaved mode rather than
        // failing to decode (which the outer try? would swallow into a reset).
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
        self.pressReturnAfterPaste = try c.decodeIfPresent(Bool.self, forKey: .pressReturnAfterPaste) ?? false
        self.contextAwarenessEnabled = try c.decodeIfPresent(Bool.self, forKey: .contextAwarenessEnabled) ?? true
        self.appendTrailingSpace = try c.decodeIfPresent(Bool.self, forKey: .appendTrailingSpace) ?? false
        // Off by default — it's opt-in (needs Screen Recording + macOS 27), so a
        // missing key (every blob predating this feature) stays disabled.
        self.windowVisionContextEnabled = try c.decodeIfPresent(Bool.self, forKey: .windowVisionContextEnabled) ?? false
        // Steps are the source of truth. A blob saved before the step model has
        // no `steps` key — read the old fixed-pass fields from their own
        // container and synthesise the equivalent list (lossless, and stable
        // across launches since ids derive from the mode id, so it doesn't churn
        // until the next save persists the real steps).
        if let decodedSteps = try c.decodeIfPresent([DictationStep].self, forKey: .steps) {
            self.steps = decodedSteps
        } else {
            let lp = try? decoder.container(keyedBy: LegacyPassKeys.self)
            func legacy<T: Decodable>(_ key: LegacyPassKeys, _ type: T.Type) -> T? {
                guard let lp else { return nil }
                return (try? lp.decodeIfPresent(type, forKey: key)) ?? nil
            }
            self.steps = Self.derivedSteps(
                modeID: self.id,
                formattingPassEnabled: legacy(.formattingPassEnabled, Bool.self) ?? true,
                formattingOverride: legacy(.formattingPromptOverride, String.self),
                formattingAddendum: legacy(.formattingPromptAddendum, String.self) ?? "",
                grammarPassMode: legacy(.grammarPassMode, GrammarPassMode.self) ?? .tighten,
                grammarOverride: legacy(.grammarPromptOverride, String.self),
                grammarAddendum: legacy(.grammarPromptAddendum, String.self) ?? "",
                grammarMaxEditFraction: legacy(.grammarPassMaxEditFraction, Double.self) ?? 0.15,
                structuralPassEnabled: legacy(.structuralPassEnabled, Bool.self) ?? true,
                structuralOverride: legacy(.structuralPromptOverride, String.self),
                structuralAddendum: legacy(.structuralPromptAddendum, String.self) ?? "",
                structuralMinWords: legacy(.structuralPassMinWords, Int.self) ?? 30)
        }
    }

    /// Memberwise init is no longer synthesised because we declared
    /// `init(from:)`. Restore it explicitly so call sites that build modes
    /// (seeds, settings UI) still compile.
    init(
        id: UUID,
        name: String,
        isLocked: Bool = false,
        includeInCycle: Bool = true,
        appBundleIDs: [String] = [],
        punctuationCuesEnabled: Bool = true,
        numberCuesEnabled: Bool = true,
        timeCuesEnabled: Bool = true,
        currencyCuesEnabled: Bool = true,
        emojiCuesEnabled: Bool = true,
        vocabularyEnabled: Bool = true,
        steps: [DictationStep] = [],
        pressReturnAfterPaste: Bool = false,
        contextAwarenessEnabled: Bool = true,
        appendTrailingSpace: Bool = false,
        windowVisionContextEnabled: Bool = false
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
        self.steps = steps
        self.pressReturnAfterPaste = pressReturnAfterPaste
        self.contextAwarenessEnabled = contextAwarenessEnabled
        self.appendTrailingSpace = appendTrailingSpace
        self.windowVisionContextEnabled = windowVisionContextEnabled
    }

    // MARK: - Prompt helper

    /// The prompt WITHOUT the global addendum — built-in (or override) plus the
    /// per-pass addendum. Used when synthesising a `DictationStep` from a legacy
    /// mode's fields (`derivedSteps`); the pipeline appends the global
    /// instructions to `step.prompt` at runtime, so global tweaks keep applying
    /// even to a step whose prompt the user has edited.
    static func bakedPrompt(builtin: String, override: String?, addendum: String) -> String {
        if let override { return override }
        let trimmed = addendum.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? builtin
            : builtin + "\n\nADDITIONAL USER INSTRUCTIONS (apply alongside everything above):\n" + trimmed
    }

    // MARK: - Seeds

    /// The locked, no-LLM Quick mode. Always present in `settings.modes`.
    static let quick = DictationMode(
        id: quickID, name: "Quick", isLocked: true, steps: [])

    /// The everyday default for fresh installs: one Format step, one LLM call.
    static let standard = DictationMode(
        id: standardID, name: "Standard",
        steps: [.format(id: legacyStepID(modeID: standardID, role: 1))])

    /// Format + a light grammar tidy.
    static let polished = DictationMode(
        id: polishedID, name: "Polished",
        steps: [
            .format(id: legacyStepID(modeID: polishedID, role: 1)),
            .grammar(id: legacyStepID(modeID: polishedID, role: 2)),
        ])

    /// Format + tighten: removes disfluencies for formal writing.
    static let formal = DictationMode(
        id: formalID, name: "Formal",
        steps: [
            .format(id: legacyStepID(modeID: formalID, role: 1)),
            .tighten(id: legacyStepID(modeID: formalID, role: 2)),
        ])
}

// MARK: - Steps

/// One LLM transformation in a mode's pipeline. A mode runs its `steps` in
/// order, each feeding the previous step's output. This replaces the old fixed
/// format → grammar → structure passes; those are now just steps seeded from
/// built-in templates, and users can add / remove / reorder their own.
struct DictationStep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Full, editable system prompt, seeded from a built-in template. Stored
    /// WITHOUT the global AI-instructions addendum — the pipeline appends that
    /// at runtime so global tweaks keep applying even to an edited prompt.
    var prompt: String
    var enabled: Bool
    /// Deterministic post-check. On failure the pipeline discards this step's
    /// output and carries the previous text forward.
    var gate: StepGate
    /// Only consulted when `gate == .maxDrift`: the word-level edit-distance
    /// ceiling above which the step's output is rejected.
    var maxDriftFraction: Double
    /// When set, the step is skipped unless the incoming text has at least this
    /// many words (the old Structure "trigger at N words").
    var minWords: Int?
    /// Token-budget tier — restructuring needs more headroom than formatting.
    var budget: StepBudget

    init(id: UUID, name: String, prompt: String, enabled: Bool = true,
         gate: StepGate = .numbersOnly, maxDriftFraction: Double = 0.15,
         minWords: Int? = nil, budget: StepBudget = .normal) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.gate = gate
        self.maxDriftFraction = maxDriftFraction
        self.minWords = minWords
        self.budget = budget
    }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, enabled, gate, maxDriftFraction, minWords, budget
    }

    /// Field-level backwards-compatible, matching the rest of the settings
    /// model: only `id` is required; everything else defaults if absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.gate = try c.decodeIfPresent(StepGate.self, forKey: .gate) ?? .none
        self.maxDriftFraction = try c.decodeIfPresent(Double.self, forKey: .maxDriftFraction) ?? 0.15
        self.minWords = try c.decodeIfPresent(Int.self, forKey: .minWords)
        self.budget = try c.decodeIfPresent(StepBudget.self, forKey: .budget) ?? .normal
    }
}

/// The deterministic post-check applied to a step's output. Mirrors the three
/// legacy pass gates plus a numbers-only and a no-op option. Only surfaced in
/// the UI under a per-step "Advanced" disclosure — new users never see it.
enum StepGate: String, Codable, Sendable, CaseIterable {
    /// ≥60% of input anchor words survive and the output doesn't balloon —
    /// catches a model that answered or continued instead of transforming.
    case anchorPreserve
    /// Bounded word-level edit distance (see `DictationStep.maxDriftFraction`).
    case maxDrift
    /// Structure-only: no word may change; bullets/breaks may be inserted.
    case wordsUnchanged
    /// Only the numbers must round-trip unchanged.
    case numbersOnly
    /// No check — accept whatever the model returns.
    case none

    var label: String {
        switch self {
        case .anchorPreserve: return "Keep the words"
        case .maxDrift: return "Limit rewriting"
        case .wordsUnchanged: return "Structure only"
        case .numbersOnly: return "Keep numbers"
        case .none: return "No check"
        }
    }
}

/// Token-budget tier for a step, mapped to concrete caps by the LLM service.
/// `expanded` is for restructuring, which legitimately grows the text with
/// list markers and line breaks; `normal` suits format/grammar rewrites.
enum StepBudget: String, Codable, Sendable, CaseIterable {
    case normal
    case expanded
}

// MARK: - Step templates

extension DictationStep {
    // Default gate is `.numbersOnly` on every template — matching the behaviour
    // deliberately settled on weeks before this redesign: the anchor / drift /
    // word-sequence checks were rejecting legitimate cleanups on short inputs
    // (very common in dictation), so only the false-positive-free
    // number-preservation revert stays on by default. The stricter gates remain
    // selectable per step under Advanced for anyone who wants them. maxDriftFraction
    // is still seeded sensibly so switching a step to `.maxDrift` has a good default.
    static func format(id: UUID, prompt: String = DictatorSettings.builtinFormattingPrompt) -> DictationStep {
        DictationStep(id: id, name: "Format", prompt: prompt, gate: .numbersOnly, budget: .normal)
    }

    static func grammar(id: UUID, prompt: String = DictatorSettings.builtinGrammarPrompt) -> DictationStep {
        DictationStep(id: id, name: "Grammar", prompt: prompt, gate: .numbersOnly, maxDriftFraction: 0.15, budget: .normal)
    }

    static func tighten(id: UUID, prompt: String = DictatorSettings.builtinTightenPrompt) -> DictationStep {
        // 0.30 seeds the drift ceiling should the user opt into `.maxDrift`;
        // tighten drops fillers, so it needs a looser ceiling than a plain tidy.
        DictationStep(id: id, name: "Tighten", prompt: prompt, gate: .numbersOnly, maxDriftFraction: 0.30, budget: .normal)
    }

    static func structure(id: UUID, prompt: String = DictatorSettings.builtinStructuralPrompt, minWords: Int = 30) -> DictationStep {
        DictationStep(id: id, name: "Structure", prompt: prompt, gate: .numbersOnly, minWords: minWords, budget: .expanded)
    }
}

// MARK: - Legacy → steps synthesis

extension DictationMode {
    /// Deterministic step id derived from the owning mode + a role tag. Keeps
    /// re-derived legacy steps stable across launches (so decode → Equatable
    /// doesn't thrash) until the first save persists them explicitly.
    static func legacyStepID(modeID: UUID, role: UInt8) -> UUID {
        var b = withUnsafeBytes(of: modeID.uuid) { Array($0) }
        b[0] ^= role
        b[15] ^= role
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The ordered step list a legacy (pre-steps) mode implies, baking each
    /// pass's effective prompt (minus the global addendum) into the step.
    static func derivedSteps(
        modeID: UUID,
        formattingPassEnabled: Bool,
        formattingOverride: String?, formattingAddendum: String,
        grammarPassMode: GrammarPassMode,
        grammarOverride: String?, grammarAddendum: String, grammarMaxEditFraction: Double,
        structuralPassEnabled: Bool,
        structuralOverride: String?, structuralAddendum: String, structuralMinWords: Int
    ) -> [DictationStep] {
        var out: [DictationStep] = []
        if formattingPassEnabled {
            out.append(.format(
                id: legacyStepID(modeID: modeID, role: 1),
                prompt: bakedPrompt(builtin: DictatorSettings.builtinFormattingPrompt,
                                    override: formattingOverride, addendum: formattingAddendum)))
        }
        switch grammarPassMode {
        case .off:
            break
        case .tidy:
            var s = DictationStep.grammar(
                id: legacyStepID(modeID: modeID, role: 2),
                prompt: bakedPrompt(builtin: DictatorSettings.builtinGrammarPrompt,
                                    override: grammarOverride, addendum: grammarAddendum))
            s.maxDriftFraction = grammarMaxEditFraction
            out.append(s)
        case .tighten:
            out.append(.tighten(
                id: legacyStepID(modeID: modeID, role: 2),
                prompt: bakedPrompt(builtin: DictatorSettings.builtinTightenPrompt,
                                    override: grammarOverride, addendum: grammarAddendum)))
        }
        if structuralPassEnabled {
            out.append(.structure(
                id: legacyStepID(modeID: modeID, role: 3),
                prompt: bakedPrompt(builtin: DictatorSettings.builtinStructuralPrompt,
                                    override: structuralOverride, addendum: structuralAddendum),
                minWords: structuralMinWords))
        }
        return out
    }
}
