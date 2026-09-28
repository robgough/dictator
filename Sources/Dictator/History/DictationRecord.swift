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

/// What happened to one LLM pass of a dictation — including the passes that
/// left no `DictationStage` behind.
///
/// Stages only record accepted *changes*, so "the model found nothing to
/// change", "its output failed a check and was thrown away" and "skipped
/// because it looked like a question" all used to look identical: a style
/// that ran nothing. That's the difference between a mode working and a mode
/// quietly failing, so it's recorded.
struct PassOutcome: Codable, Hashable, Sendable {
    enum Kind: String {
        case changed, unchanged, rejected, skipped, failed
    }

    /// The pass's display name ("Polish", "Paragraphs"), matching its stage.
    let pass: String
    /// A `Kind` raw value, stored as a plain string on purpose: history is
    /// one JSON array, and a record from a newer build carrying a kind this
    /// build doesn't know must still decode rather than take the whole file
    /// down with it.
    let result: String
    /// Why, in words for the History pane. nil for a plain accepted change.
    let detail: String?

    init(pass: String, _ kind: Kind, detail: String? = nil) {
        self.pass = pass
        self.result = kind.rawValue
        self.detail = detail
    }

    var kind: Kind? { Kind(rawValue: result) }

    /// Rejected or failed: something went wrong, not just "nothing to do".
    var isProblem: Bool { kind == .rejected || kind == .failed }
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

    /// One entry per pass that was attempted, in order. nil on records
    /// written before outcomes were tracked, and on modes that run no pass.
    let passOutcomes: [PassOutcome]?
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

    /// One step of the one-line summary of what a dictation went through.
    struct TrailStep: Hashable {
        enum Tone { case normal, quiet, problem }
        let label: String
        let tone: Tone
    }

    /// "Transcript › Polish (no changes) › Paragraphs" as data, so the menu
    /// bar and History render the same summary. Built from `passOutcomes`
    /// when the record has them — that's what shows a pass that ran and
    /// changed nothing, or was rejected — and from the stages otherwise.
    var trail: [TrailStep] {
        let adjusted = versions.last?.name == Self.adjustedStageName
        guard let outcomes = passOutcomes, !outcomes.isEmpty else {
            return versions.map { version in
                switch version.name {
                case "Dictionary-corrected": TrailStep(label: "Dictionary", tone: .normal)
                case Self.adjustedStageName: TrailStep(label: "Adjusted", tone: .normal)
                default: TrailStep(label: version.name, tone: .normal)
                }
            }
        }
        var steps = [TrailStep(label: "Transcript", tone: .normal)]
        for (index, outcome) in outcomes.enumerated() {
            switch outcome.kind {
            case .changed?: steps.append(TrailStep(label: outcome.pass, tone: .normal))
            case .unchanged?: steps.append(TrailStep(label: "\(outcome.pass) (no changes)", tone: .quiet))
            case .skipped?: steps.append(TrailStep(label: "\(outcome.pass) (skipped)", tone: .quiet))
            case .rejected?: steps.append(TrailStep(label: "\(outcome.pass) (rejected)", tone: .problem))
            case .failed?: steps.append(TrailStep(label: "\(outcome.pass) (failed)", tone: .problem))
            case nil: steps.append(TrailStep(label: outcome.pass, tone: .quiet))
            }
            // The dictionary runs straight after the first pass.
            if index == 0, dictionaryCorrected != nil {
                steps.append(TrailStep(label: "Dictionary", tone: .normal))
            }
        }
        if adjusted { steps.append(TrailStep(label: "Adjusted", tone: .normal)) }
        return steps
    }

    /// The outcomes worth a sentence: anything with a reason attached.
    var outcomeNotes: [PassOutcome] {
        (passOutcomes ?? []).filter { $0.detail != nil }
    }

    /// The stage `versions` adds when delivery changed the text beyond
    /// whitespace.
    static let adjustedStageName = "Adjusted to fit"

    private static func visiblyDiffers(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            != b.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
