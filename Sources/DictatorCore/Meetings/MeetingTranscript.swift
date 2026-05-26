import Foundation

/// One word within a transcript segment with its time range. v0.2 fills
/// these from Parakeet's token-level timings so the diarizer can attribute
/// each word to a speaker; we keep them on disk so future search can match
/// queries against precise audio positions without re-transcribing.
struct TranscriptWord: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String

    init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Single rendered turn in a meeting transcript. `words` is filled by the
/// v0.2 word-aligned pipeline; older transcripts on disk decode it as nil
/// and the UI renders them by sentence as before.
struct MeetingTranscriptSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var speakerId: String
    var text: String
    var words: [TranscriptWord]?

    init(start: Double, end: Double, speakerId: String, text: String, words: [TranscriptWord]? = nil) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
        self.words = words
    }
}

/// Codable shape for `transcript.json`. One file per meeting folder.
struct MeetingTranscript: Codable, Equatable, Sendable {
    var segments: [MeetingTranscriptSegment]
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    init(segments: [MeetingTranscriptSegment], schemaVersion: Int = MeetingTranscript.currentSchemaVersion) {
        self.segments = segments
        self.schemaVersion = schemaVersion
    }
}
