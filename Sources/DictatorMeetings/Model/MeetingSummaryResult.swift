import Foundation

/// Codable shape for the optional summary block on `MeetingMeta`. The LLM
/// produces this JSON directly; we round-trip it onto disk under
/// `meta.summary` so the UI can re-render the same digest without re-running
/// the model.
struct MeetingSummaryResult: Codable, Equatable, Sendable {
    /// Concrete agreed outcomes — never topics discussed.
    var decisions: [String]
    /// Tasks with an owner if the transcript names one.
    var actionItems: [ActionItem]
    /// Short factual narrative — 3–6 sentences.
    var narrative: String
    /// Identifier of the LLM that produced this — surfaced in the UI so
    /// users can tell "this was an Apple Foundation summary" from "this
    /// was Llama 3.2 3B."
    var modelID: String
    var generatedAt: Date

    struct ActionItem: Codable, Equatable, Sendable {
        /// Null when the transcript didn't name an owner — the prompt is
        /// strict about this so the model doesn't invent names.
        var owner: String?
        var text: String
    }
}
