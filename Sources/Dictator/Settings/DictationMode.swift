import Foundation

/// The LLM treatment a dictation mode applies. Replaces the free-form step list
/// that shipped in July 2026: a mode now *references* a style, and the prompts
/// for that style live in code (`DictatorSettings.builtin…Prompt`). That means
/// prompt improvements reach every existing mode on update — under the step
/// model each mode carried a frozen copy of its prompt, so edits in code never
/// reached anyone who had already saved.
enum DictationStyle: String, Codable, CaseIterable, Sendable {
    /// No LLM at all. Spoken cues + vocabulary only — the floor.
    case raw
    /// One Format pass. Verbatim wording; punctuation, casing and spoken cues.
    /// Fillers are kept.
    case clean
    /// Format, then Polish: fillers and false starts go, the result reads as
    /// written English rather than a transcript.
    case polished
    /// One short-form pass tuned for chat: casual register, no sign-offs, no
    /// paragraphing.
    case messages
    /// One pass with the mode's own full prompt (`DictationMode.customPrompt`).
    case custom

    var label: String {
        switch self {
        case .raw: return "Raw"
        case .clean: return "Clean"
        case .polished: return "Polished"
        case .messages: return "Messages"
        case .custom: return "Custom"
        }
    }

    /// One line of UI copy under the style picker / on a gallery card.
    var summary: String {
        switch self {
        case .raw:
            return "No AI. The transcript exactly as heard, with your cues and dictionary."
        case .clean:
            return "Punctuation and casing, ums and stutters removed — otherwise your words, as you said them."
        case .polished:
            return "Clean, then tidied: \"you know\" fillers, false starts and grammar slips removed — reads as written."
        case .messages:
            return "Short-form chat: casual register, no sign-offs, no paragraphs."
        case .custom:
            return "One pass with a prompt you write yourself."
        }
    }

    /// False only for `.raw` — every other style runs at least one LLM pass.
    var usesLLM: Bool { self != .raw }

    /// Whether the pipeline may insert paragraph breaks into a long dictation
    /// after the passes have run. Off for `.raw` (no LLM at all) and
    /// `.messages` (a chat message is one block by definition).
    var autoParagraphs: Bool {
        switch self {
        case .clean, .polished, .custom: return true
        case .raw, .messages: return false
        }
    }
}

/// One resolved LLM transformation. Built from a mode's style (plus its custom
/// prompt) at the moment the pipeline runs, so `prompt` is always the current
/// built-in text — never a stale copy from disk.
///
/// `prompt` is the BASE prompt only: no per-mode extra instructions and no
/// global instructions. `DictatorSettings.assemblePrompt` layers those on at
/// call time.
struct DictationPass: Equatable, Sendable {
    enum Kind: String, Sendable { case format, polish, messages, custom }
    let kind: Kind
    /// HUD + history label.
    let name: String
    let prompt: String
}

/// A named bundle of dictation post-processing settings.
///
/// Each mode picks a `style` (its LLM treatment — see `DictationStyle`) plus the
/// deterministic pre-processing toggles, context, and delivery options. The user
/// picks a default mode from the menu bar; the active mode can be cycled
/// mid-recording with a key (default: Tab).
///
/// Fresh installs seed a curated set: **Quick** (`isLocked == true`, `.raw` —
/// the transcript through cues + vocabulary, the floor), **Standard**
/// (`.clean`, the default), **Polished** (`.polished`) and **Messages**
/// (`.messages`, bound to the common chat apps). Users can add more from the
/// "+" gallery (`galleryTemplates`).
///
/// Modes saved under the step model (July 2026) or before it are migrated on
/// decode — see `init(from:)` and `migratedStyle(fromSteps:isLocked:)`.
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

    /// The LLM treatment this mode applies. Source of truth for `passes`.
    var style: DictationStyle

    /// Appended (under a labelled header) to EVERY LLM pass this mode runs.
    /// "" means none. This is where "always British spelling" or "keep my
    /// bullet cues" lives — the built-in prompt itself is never edited.
    var extraInstructions: String

    /// Only used when `style == .custom`: the full system prompt for the single
    /// pass. Empty falls back to `DictatorSettings.builtinFormattingPrompt` at
    /// runtime so a half-configured custom mode still does something sensible.
    var customPrompt: String

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

    // MARK: - Resolved pipeline

    /// The ordered LLM passes this mode runs, resolved from `style` against the
    /// CURRENT built-in prompts. `.raw` runs none.
    ///
    /// Each pass's `prompt` is the base text only — the pipeline layers
    /// `extraInstructions` and the global instructions on with
    /// `DictatorSettings.assemblePrompt`.
    var passes: [DictationPass] {
        switch style {
        case .raw:
            return []
        case .clean:
            return [DictationPass(kind: .format, name: "Format",
                                  prompt: DictatorSettings.builtinFormattingPrompt)]
        case .polished:
            return [
                DictationPass(kind: .format, name: "Format",
                              prompt: DictatorSettings.builtinFormattingPrompt),
                DictationPass(kind: .polish, name: "Polish",
                              prompt: DictatorSettings.builtinPolishPrompt),
            ]
        case .messages:
            return [DictationPass(kind: .messages, name: "Messages",
                                  prompt: DictatorSettings.builtinMessagesPrompt)]
        case .custom:
            return [DictationPass(kind: .custom, name: "Custom",
                                  prompt: resolvedCustomPrompt)]
        }
    }

    /// `customPrompt` with the empty-string fallback applied.
    var resolvedCustomPrompt: String {
        let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DictatorSettings.builtinFormattingPrompt : customPrompt
    }

    /// Whether the pipeline should run the automatic paragraph split on long
    /// dictations produced by this mode.
    var runsAutoParagraphs: Bool { style.autoParagraphs }

    // MARK: - Stable IDs for the built-ins

    /// Hard-coded UUID for the built-in Quick mode. Stable across launches so
    /// other code can reliably reference "the Quick mode" without a name lookup.
    static let quickID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// Hard-coded UUID for the seed Write mode. Users can rename or delete it
    /// after creation, so existence isn't guaranteed — only the freshly-migrated
    /// or freshly-installed state has this id present. Retained because the
    /// pre-modes migration (`synthesiseLegacyModes`) still mints it.
    static let writeID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    /// Stable IDs for the curated seed modes. Fresh installs get all of these;
    /// equivalents can also be added later from the "+" gallery, which mints
    /// fresh ids so the user can keep several.
    static let standardID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let polishedID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let messagesID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

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
        case style, extraInstructions, customPrompt
        case steps
        case pressReturnAfterPaste, contextAwarenessEnabled, appendTrailingSpace
        case windowVisionContextEnabled
    }

    /// Side container for the legacy single `spokenCuesEnabled` toggle.
    /// Kept off the main CodingKeys enum so the encoder doesn't try to write a
    /// property that no longer exists; we just peek at the field on decode and
    /// use its value as the default for the new sub-toggles.
    private enum LegacyCueKey: String, CodingKey {
        case spokenCuesEnabled
    }

    /// Side container for the pre-step fixed-pass fields. Read only during
    /// decode of a blob that has neither `style` nor `steps`, to reconstruct the
    /// implied step list before mapping it to a style; never encoded.
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

        // Style is the source of truth. When it's present we ignore `steps`
        // entirely — a new build's own blob (and the COMPAT SHADOW steps it
        // writes for older builds on the same synced folder) always carries it.
        if let decodedStyle = try c.decodeIfPresent(DictationStyle.self, forKey: .style) {
            self.style = decodedStyle
            self.extraInstructions = try c.decodeIfPresent(String.self, forKey: .extraInstructions) ?? ""
            self.customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
            return
        }

        // No style: this blob is either step-shaped (July 2026) or pre-steps.
        // Reconstruct the legacy step list, then map it onto a style.
        let legacySteps: [DictationStep]
        if let decodedSteps = try c.decodeIfPresent([DictationStep].self, forKey: .steps) {
            legacySteps = decodedSteps
        } else {
            let lp = try? decoder.container(keyedBy: LegacyPassKeys.self)
            func legacy<T: Decodable>(_ key: LegacyPassKeys, _ type: T.Type) -> T? {
                guard let lp else { return nil }
                return (try? lp.decodeIfPresent(type, forKey: key)) ?? nil
            }
            legacySteps = Self.derivedSteps(
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

        let migrated = Self.migratedStyle(fromSteps: legacySteps, isLocked: self.isLocked)
        self.style = migrated.style
        self.extraInstructions = migrated.extraInstructions
        self.customPrompt = migrated.customPrompt
        NSLog("[Dictator] Mode migration: \"%@\" steps=[%@] → style=%@ extraInstructions=%d chars customPrompt=%d chars",
              self.name,
              legacySteps.map { "\($0.name)\($0.enabled ? "" : "(off)")" }.joined(separator: ","),
              migrated.style.rawValue,
              migrated.extraInstructions.count,
              migrated.customPrompt.count)
    }

    /// Hand-rolled encode so we can ALSO emit the legacy `steps` shadow (see
    /// `legacyShadowSteps`). Everything else is a straight field write.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(includeInCycle, forKey: .includeInCycle)
        try c.encode(appBundleIDs, forKey: .appBundleIDs)
        try c.encode(punctuationCuesEnabled, forKey: .punctuationCuesEnabled)
        try c.encode(numberCuesEnabled, forKey: .numberCuesEnabled)
        try c.encode(timeCuesEnabled, forKey: .timeCuesEnabled)
        try c.encode(currencyCuesEnabled, forKey: .currencyCuesEnabled)
        try c.encode(emojiCuesEnabled, forKey: .emojiCuesEnabled)
        try c.encode(vocabularyEnabled, forKey: .vocabularyEnabled)
        try c.encode(style, forKey: .style)
        try c.encode(extraInstructions, forKey: .extraInstructions)
        try c.encode(customPrompt, forKey: .customPrompt)
        try c.encode(pressReturnAfterPaste, forKey: .pressReturnAfterPaste)
        try c.encode(contextAwarenessEnabled, forKey: .contextAwarenessEnabled)
        try c.encode(appendTrailingSpace, forKey: .appendTrailingSpace)
        try c.encode(windowVisionContextEnabled, forKey: .windowVisionContextEnabled)
        // COMPAT SHADOW — remove one release after v2026.9.
        // Settings sync across the user's Macs through the Documents folder. An
        // older build reading a blob with no `steps` key falls back to the
        // legacy defaults (exactly the bug this phase fixes) and, on its next
        // save, would clobber the custom prompts. So we keep writing an
        // equivalent step list derived from the style. New builds ignore it
        // whenever `style` is present.
        try c.encode(legacyShadowSteps, forKey: .steps)
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
        style: DictationStyle = .clean,
        extraInstructions: String = "",
        customPrompt: String = "",
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
        self.style = style
        self.extraInstructions = extraInstructions
        self.customPrompt = customPrompt
        self.pressReturnAfterPaste = pressReturnAfterPaste
        self.contextAwarenessEnabled = contextAwarenessEnabled
        self.appendTrailingSpace = appendTrailingSpace
        self.windowVisionContextEnabled = windowVisionContextEnabled
    }

    // MARK: - Prompt helper

    /// The prompt WITHOUT the global addendum — built-in (or override) plus a
    /// per-pass addendum. Used when synthesising legacy `DictationStep`s (both
    /// the pre-steps decode path and the COMPAT SHADOW encode).
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
        id: quickID, name: "Quick", isLocked: true, style: .raw)

    /// The everyday default for fresh installs: one Format pass.
    static let standard = DictationMode(
        id: standardID, name: "Standard", style: .clean)

    /// Format + Polish: drops fillers and false starts.
    static let polished = DictationMode(
        id: polishedID, name: "Polished", style: .polished)

    /// Short-form chat formatting, pre-bound to the usual messaging apps so it
    /// auto-activates there without the user configuring anything.
    static let messages = DictationMode(
        id: messagesID, name: "Messages",
        appBundleIDs: [
            "com.apple.MobileSMS",
            "com.tinyspeck.slackmacgap",
            "net.whatsapp.WhatsApp",
            "com.hnc.Discord",
            "org.whispersystems.signal-desktop",
            "ru.keepcoder.Telegram",
        ],
        style: .messages)

    /// The "+" gallery: one card per style. Ids are minted fresh on install
    /// (`ModesPane.installMode`), so a template can be added more than once.
    static var galleryTemplates: [DictationMode] {
        [
            DictationMode(id: UUID(), name: "Clean", style: .clean),
            DictationMode(id: UUID(), name: "Polished", style: .polished),
            DictationMode(id: UUID(), name: "Messages", style: .messages),
            DictationMode(id: UUID(), name: "Raw", style: .raw),
            DictationMode(id: UUID(), name: "Custom", style: .custom,
                          customPrompt: DictatorSettings.builtinFormattingPrompt),
        ]
    }
}

// MARK: - Steps → style migration

extension DictationMode {
    /// What a legacy step's stored prompt was originally seeded from. Classified
    /// by prefix because the step model baked a full copy of the prompt into
    /// every mode and dropped the role — the prefix is the only signal left.
    enum LegacyStepRole {
        case format, grammar, tighten, structure, messages, custom
    }

    static func legacyRole(ofPrompt prompt: String) -> LegacyStepRole {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("You are a strict, deterministic dictation formatter") { return .format }
        if p.hasPrefix("You are a GRAMMAR TIDYING") { return .grammar }
        if p.hasPrefix("You are a GRAMMAR + TIGHTENING") { return .tighten }
        if p.hasPrefix("You are a STRUCTURAL") { return .structure }
        // The two headers the COMPAT SHADOW writes. Recognising them means a
        // blob that round-trips through an OLDER build (which strips `style`
        // and re-saves only `steps`) still comes back as the right style
        // instead of collapsing into `.custom`.
        if p.hasPrefix("You are a POLISHING") { return .tighten }
        if p.hasPrefix("You are a strict, deterministic formatter for SHORT MESSAGES") { return .messages }
        return .custom
    }

    /// Maps a legacy step list onto the new style model.
    ///
    /// The July 2026 steps migration synthesised an identical
    /// Format → Tighten → Structure ladder into most modes (including the
    /// locked Quick mode, which is documented as "no LLM"), so the mapping is
    /// deliberately coarse: what matters is whether the user had a real custom
    /// prompt, whether they had a disfluency-removing pass, and whether their
    /// format prompt carried instructions of their own.
    static func migratedStyle(fromSteps steps: [DictationStep], isLocked: Bool)
        -> (style: DictationStyle, extraInstructions: String, customPrompt: String) {
        // Quick is documented as the no-LLM floor; the ladder it was given in
        // July was never intended. Restore the documented behaviour.
        if isLocked { return (.raw, "", "") }

        let enabled = steps.filter(\.enabled)
        guard !enabled.isEmpty else { return (.raw, "", "") }

        let roles = enabled.map { legacyRole(ofPrompt: $0.prompt) }

        // A hand-written prompt in first position IS the mode. Later steps are
        // dropped — they were the synthesised ladder, not a considered choice.
        if roles.first == .custom {
            return (.custom, "", enabled[0].prompt)
        }

        // A shadow-written Messages step round-tripping back from an older
        // build. Recover its extra instructions the same way.
        if roles.first == .messages {
            let extra = recoveredExtraInstructions(
                from: enabled[0].prompt, builtin: DictatorSettings.builtinMessagesPrompt)
            return (.messages, extra, "")
        }

        let extra = enabled.indices
            .first(where: { roles[$0] == .format })
            .map { recoveredExtraInstructions(fromFormatPrompt: enabled[$0].prompt) } ?? ""

        let hasCleanup = roles.contains(.tighten) || roles.contains(.grammar)
        return (hasCleanup ? .polished : .clean, extra, "")
    }

    /// Recovers the user's own instructions from a stored Format prompt: the
    /// non-blank lines that don't appear in the current built-in.
    ///
    /// The July migration baked `formattingPromptAddendum` into the prompt copy
    /// (and some users then edited the copy directly), so a line-set difference
    /// is the only way to get those instructions back out. Header lines and the
    /// GLOBAL INSTRUCTIONS block are dropped — the pipeline re-adds both.
    /// Capped at 2000 characters so a wholesale rewrite doesn't turn into a
    /// giant addendum on top of the built-in.
    static func recoveredExtraInstructions(fromFormatPrompt prompt: String) -> String {
        recoveredExtraInstructions(
            from: prompt,
            builtin: DictatorSettings.builtinFormattingPrompt + "\n" + legacyFormattingPromptLines.joined(separator: "\n"))
    }

    /// Lines of `builtinFormattingPrompt` as it shipped Jul–Aug 2026, when the
    /// steps model copied it into every mode, that have since been reworded.
    /// The line-set diff treats them as built-in too, so an old copy's former
    /// rule 6 doesn't come back as a recovered "extra instruction" that
    /// re-imposes the retired keep-every-filler rule. Append the previous
    /// wording here whenever a Format-prompt line is edited. Delete with the
    /// COMPAT SHADOW.
    static let legacyFormattingPromptLines: [String] = [
        "6. Preserve the user's wording and tone. EVERY content word in the input MUST appear in the output, in the same order. Do NOT drop filler words (\"yeah\", \"okay\", \"so\", \"well\", \"um\"). Do NOT paraphrase. Do NOT reorder. Do NOT continue their thought. Do NOT add ideas, examples, plans, opinions, greetings, sign-offs, or any new content.",
        "Rule 6 still binds: NEVER change vocabulary, NEVER reorder, NEVER drop content words.",
    ]

    /// Line-set difference of `prompt` against `builtin` — see
    /// `recoveredExtraInstructions(fromFormatPrompt:)`.
    static func recoveredExtraInstructions(from prompt: String, builtin: String) -> String {
        let builtinLines = Set(
            builtin
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) })
        var out: [String] = []
        var inGlobalBlock = false
        for rawLine in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Everything from the GLOBAL INSTRUCTIONS header to the end of the
            // prompt is re-applied at runtime from settings; never recover it.
            if line.hasPrefix("GLOBAL INSTRUCTIONS") { inGlobalBlock = true; continue }
            if inGlobalBlock { continue }
            if line.hasPrefix("ADDITIONAL USER INSTRUCTIONS") { continue }
            if builtinLines.contains(line) { continue }
            out.append(line)
        }
        let joined = out.joined(separator: "\n")
        return joined.count > 2000 ? String(joined.prefix(2000)) : joined
    }
}

// MARK: - Legacy steps (decode + compat-encode only)

/// One LLM transformation in the July 2026 step model. NOT part of the live
/// data model any more: `DictationMode` resolves its pipeline from `style`.
/// This type survives only so we can (a) decode a step-shaped blob and map it
/// onto a style, and (b) keep writing a `steps` shadow for older builds sharing
/// the same synced settings file.
///
/// Legacy decode + compat-shadow only. Nothing outside this file may use it.
struct DictationStep: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    /// Full system prompt, stored WITHOUT the global AI-instructions addendum.
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

/// The deterministic post-check applied to a legacy step's output. Decode-only.
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

/// Token-budget tier for a legacy step. Decode-only.
enum StepBudget: String, Codable, Sendable, CaseIterable {
    case normal
    case expanded
}

// MARK: - Legacy step templates

extension DictationStep {
    static func format(id: UUID, prompt: String = DictatorSettings.builtinFormattingPrompt) -> DictationStep {
        DictationStep(id: id, name: "Format", prompt: prompt, gate: .numbersOnly, budget: .normal)
    }

    static func grammar(id: UUID, prompt: String = DictatorSettings.builtinGrammarPrompt) -> DictationStep {
        DictationStep(id: id, name: "Grammar", prompt: prompt, gate: .numbersOnly, maxDriftFraction: 0.15, budget: .normal)
    }

    static func tighten(id: UUID, prompt: String = DictatorSettings.builtinPolishPrompt) -> DictationStep {
        // 0.30 seeds the drift ceiling should the user opt into `.maxDrift`;
        // tighten drops fillers, so it needs a looser ceiling than a plain tidy.
        DictationStep(id: id, name: "Tighten", prompt: prompt, gate: .numbersOnly, maxDriftFraction: 0.30, budget: .normal)
    }

    static func structure(id: UUID, prompt: String = DictatorSettings.builtinStructuralPrompt, minWords: Int = 30) -> DictationStep {
        DictationStep(id: id, name: "Structure", prompt: prompt, gate: .numbersOnly, minWords: minWords, budget: .expanded)
    }
}

// MARK: - Legacy → steps synthesis (pre-steps blobs only)

extension DictationMode {
    /// Deterministic step id derived from the owning mode + a role tag. Keeps
    /// derived / shadow steps stable across launches so an older build reading
    /// the shadow doesn't see the ids churn on every save.
    static func legacyStepID(modeID: UUID, role: UInt8) -> UUID {
        var b = withUnsafeBytes(of: modeID.uuid) { Array($0) }
        b[0] ^= role
        b[15] ^= role
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The ordered step list a legacy (pre-steps) mode implies, baking each
    /// pass's effective prompt (minus the global addendum) into the step. Feeds
    /// straight into `migratedStyle(fromSteps:isLocked:)`.
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
                prompt: bakedPrompt(builtin: DictatorSettings.builtinPolishPrompt,
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

// MARK: - Compat shadow for older builds

extension DictationMode {
    /// The legacy `steps` list this mode's style implies. Written by
    /// `encode(to:)` so an older build reading the same synced settings file
    /// still sees a sane pipeline instead of falling back to its defaults.
    ///
    /// COMPAT SHADOW — remove one release after v2026.9.
    var legacyShadowSteps: [DictationStep] {
        func baked(_ builtin: String) -> String {
            Self.bakedPrompt(builtin: builtin, override: nil, addendum: extraInstructions)
        }
        switch style {
        case .raw:
            return []
        case .clean:
            return [.format(id: Self.legacyStepID(modeID: id, role: 1),
                            prompt: baked(DictatorSettings.builtinFormattingPrompt))]
        case .polished:
            return [
                .format(id: Self.legacyStepID(modeID: id, role: 1),
                        prompt: baked(DictatorSettings.builtinFormattingPrompt)),
                .tighten(id: Self.legacyStepID(modeID: id, role: 2),
                         prompt: baked(DictatorSettings.builtinPolishPrompt)),
            ]
        case .messages:
            return [.format(id: Self.legacyStepID(modeID: id, role: 1),
                            prompt: baked(DictatorSettings.builtinMessagesPrompt))]
        case .custom:
            return [.format(id: Self.legacyStepID(modeID: id, role: 1),
                            prompt: resolvedCustomPrompt)]
        }
    }
}
