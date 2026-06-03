import Foundation

/// Markdown meeting notes — the primary artifact for a meeting. The LLM
/// authors the markdown directly (no intermediate JSON schema); we round-trip
/// it onto disk under `meta.notes` so the UI can re-render and the user can
/// copy/paste it verbatim into a notes app.
///
/// Two flavours live in the same shape, distinguished by `isFinal`:
///   - the *live first-pass* built incrementally while the meeting records
///     (`isFinal == false`), and
///   - the *full* pass produced once the meeting stops and the canonical
///     diarized transcript exists (`isFinal == true`), which supersedes it.
///
/// Supersedes `MeetingSummaryResult` for new meetings. Old meetings that only
/// carry the structured `meta.summary` still render via the back-compat path
/// in `MeetingExporter` / the notes UI.
struct MeetingNotes: Codable, Equatable, Sendable {
    /// The notes body as markdown. Starts at the first section heading
    /// (`## Summary`) — the meeting title is rendered separately as the H1,
    /// so the model is told not to emit one.
    var markdown: String
    /// Identifier of the LLM that produced this — surfaced in the UI so the
    /// user can tell an Apple Foundation pass from a local MLX model.
    var modelID: String
    var generatedAt: Date
    /// False while this is the live first-pass built during recording; true
    /// once the end-of-meeting pass has produced the finished notes.
    var isFinal: Bool

    init(markdown: String, modelID: String, generatedAt: Date, isFinal: Bool) {
        self.markdown = markdown
        self.modelID = modelID
        self.generatedAt = generatedAt
        self.isFinal = isFinal
    }
}
