import Foundation

/// One accepted transformation in a dictation's journey — the output of an LLM
/// pass, or of the automatic paragraph split. Named after the pass
/// (`DictationPass.name`: "Format", "Polish", "Messages", "Custom") or
/// "Paragraphs", so the History pane can label the row without knowing anything
/// about the style that produced it.
///
/// Only ACCEPTED stages are recorded: a pass whose output failed its gate (or
/// came back empty) leaves no stage behind, because the text carried forward is
/// the previous stage's.
struct DictationStage: Codable, Equatable, Hashable, Sendable {
    let name: String
    let text: String
}

struct DictationRecord: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date

    /// Raw Whisper output.
    let raw: String

    /// The style the mode was set to (`DictationStyle.label`) — "Clean",
    /// "Polished", … nil on records written before styles existed.
    let style: String?
    /// The ordered LLM stages this dictation actually went through. nil on
    /// records written before styles existed (those carry the fixed
    /// formatted/tidied/restructured fields below instead) and on records with
    /// no LLM stages at all.
    let stages: [DictationStage]?

    /// LEGACY (pre-styles). Output of pass 1 (formatter). Still written for new
    /// records — set to the first accepted stage's text — so a History pane that
    /// hasn't been taught about `stages` yet keeps showing something useful.
    let formatted: String?
    /// After applying the user's dictionary. nil if no entries matched.
    let dictionaryCorrected: String?
    /// LEGACY (pre-styles). Output of optional pass 2 (grammar). New records put
    /// any non-first LLM stage here.
    let tidied: String?
    /// LEGACY (pre-styles). Output of optional pass 3 (structure). New records
    /// put the automatic paragraph split here.
    let restructured: String?
    /// What we actually delivered to the user (pasted or copied).
    let final: String

    /// True if synthetic ⌘V paste was attempted (Accessibility granted).
    let pasted: Bool
    let inputDevice: String
    let note: String?

    /// Bundle ID of the app that was frontmost when the hotkey fired — where
    /// the text was delivered. Diagnostics only (no UI): join/spacing quirks
    /// are app-specific, and this is what makes "which apps did this happen
    /// in?" answerable after the fact. nil on records written before it
    /// existed, and whenever the frontmost app couldn't be identified.
    let appBundleID: String?

    /// How many spelling terms a window-vision read contributed to this
    /// dictation.
    ///
    /// True when this was actually written to the user's journal file.
    ///
    /// Not simply "came from the journal hotkey": a journal write that fails
    /// falls back to the clipboard, and that run should read as the clipboard
    /// fallback it is rather than as a filed entry. So this mirrors
    /// `Pipeline.lastDeliveryWasJournal`, which the failure path clears.
    ///
    /// Needed because `pasted` can't carry it. Journal entries deliberately
    /// never touch the app or the clipboard, so `pasted` is false for them —
    /// the same false a genuine clipboard fallback produces. The menu bar was
    /// reading that as "only reached the clipboard" and tinting successful
    /// journal entries with the warning colour. nil on older records.
    let deliveredToJournal: Bool?

    /// Three states, deliberately: **nil** means no read was attempted (vision
    /// is off for this mode, unsupported, or Screen Recording isn't granted) —
    /// which is also what old records decode to. **0** means a read ran and
    /// came back with nothing usable. **Positive** is the happy path.
    ///
    /// Recorded because window vision is otherwise invisible: it feeds a
    /// spelling reference into the prompt and then disappears, so there was no
    /// way to tell a run that used it from one that didn't — which made it
    /// impossible to judge whether the feature was working at all.
    let visionTermCount: Int?

}
