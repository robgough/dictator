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

extension DictationRecord {
    /// `style` for display. Records written before the no-LLM style was
    /// renamed carry "Raw"; it's the same style, now called Quick.
    var styleLabel: String? {
        style == "Raw" ? DictationStyle.raw.label : style
    }

    /// Every distinct text this dictation passed through, in pipeline order,
    /// each labelled with the stage that produced it — the transcript first,
    /// what was delivered last.
    ///
    /// Shared by the History pane and the menu bar's versions popover so the
    /// two can't disagree about what a dictation went through. Handles both
    /// record shapes: the ordered `stages` model, and legacy records that
    /// carry the fixed formatted/tidied/restructured fields instead.
    ///
    /// The delivered text only gets its own entry when delivery changed
    /// something you could see. Nearly every dictation gains a trailing space
    /// on the way out (so the next one doesn't glue onto it), and listing an
    /// identical-looking "final" after every stage was noise. What's left —
    /// the caret-aware join recasing the first word or dropping a full stop,
    /// spoken cues re-applied after the model reverted them — is a real
    /// processing step, and shows as one (`adjustedStageName`).
    var versions: [DictationStage] {
        var out = [DictationStage(name: "Transcript", text: raw)]
        if let stages, !stages.isEmpty {
            out += stages
            if let c = dictionaryCorrected {
                out.append(DictationStage(name: "Dictionary-corrected", text: c))
            }
            if Self.visiblyDiffers(final, stages.last!.text) {
                out.append(DictationStage(name: Self.adjustedStageName, text: final))
            }
        } else {
            if let f = formatted, f != raw {
                out.append(DictationStage(name: "Formatted", text: f))
            }
            if let c = dictionaryCorrected {
                out.append(DictationStage(name: "Dictionary-corrected", text: c))
            }
            if let t = tidied { out.append(DictationStage(name: "Grammar-tidied", text: t)) }
            if let r = restructured { out.append(DictationStage(name: "Restructured", text: r)) }
            if Self.visiblyDiffers(final, restructured ?? tidied ?? dictionaryCorrected ?? formatted ?? raw) {
                out.append(DictationStage(name: Self.adjustedStageName, text: final))
            }
        }
        return out
    }

    /// The stage `versions` adds when delivery changed the text beyond
    /// whitespace.
    static let adjustedStageName = "Adjusted to fit"

    private static func visiblyDiffers(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            != b.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
