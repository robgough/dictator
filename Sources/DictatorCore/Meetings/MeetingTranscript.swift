import Foundation

/// Single rendered turn in a meeting transcript. v0.1 has no word-level
/// timings — `words` stays absent until v0.2 lands word-aligned ASR.
struct MeetingTranscriptSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var speakerId: String
    var text: String

    init(start: Double, end: Double, speakerId: String, text: String) {
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.text = text
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
