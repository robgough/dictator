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
}
