import Foundation

/// Lightweight metadata about a single meeting. One JSON blob per folder
/// at `~/Library/Application Support/Dictator/Meetings/<uuid>/meta.json`.
///
/// v0.1 carries enough shape to grow into the v0.2 diarization world without
/// schema churn — `speakers` is already an array, the v0.1 happy path just
/// emits two entries ("Me" + "Other").
struct MeetingMeta: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case live    // captured via SCStream (mic + system)
        case fileImport = "import"
    }

    struct Speaker: Codable, Equatable, Sendable {
        var id: String                  // "me", "other", "speaker_1", …
        var displayName: String         // user-editable
        var colorHex: String            // "#RRGGBB"
        var isMe: Bool

        enum CodingKeys: String, CodingKey {
            case id, displayName, colorHex = "color", isMe
        }

        init(id: String, displayName: String, colorHex: String, isMe: Bool = false) {
            self.id = id
            self.displayName = displayName
            self.colorHex = colorHex
            self.isMe = isMe
        }
    }

    struct AudioFiles: Codable, Equatable, Sendable {
        var mic: String?
        var system: String?
    }

    var id: UUID
    var title: String
    var createdAt: Date
    var durationSeconds: Double
    var source: Source
    var sourceFilename: String?
    var audioFiles: AudioFiles
    var speakers: [Speaker]
    /// Optional — present only after the user (or the auto-run path) has run
    /// the LLM summary pass. Old meetings decode this as nil and render
    /// without a summary section.
    var summary: MeetingSummaryResult?
    /// Conversational shape of the meeting (1-on-1, stand-up, retro, …).
    /// Drives which prompt addendum the summary pass tacks on. `.auto`
    /// lets the model decide from the transcript; older meta.json blobs
    /// that pre-date this field decode as `.auto`.
    var meetingType: MeetingType
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        durationSeconds: Double,
        source: Source,
        sourceFilename: String? = nil,
        audioFiles: AudioFiles,
        speakers: [Speaker],
        summary: MeetingSummaryResult? = nil,
        meetingType: MeetingType = .auto,
        schemaVersion: Int = MeetingMeta.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.source = source
        self.sourceFilename = sourceFilename
        self.audioFiles = audioFiles
        self.speakers = speakers
        self.summary = summary
        self.meetingType = meetingType
        self.schemaVersion = schemaVersion
    }

    /// Backwards-compatible decode: every field added after v0.1
    /// (`summary`, `meetingType`, `sourceFilename`) falls back to its
    /// safe default when missing from the persisted JSON, so older
    /// meeting folders keep loading after a Dictator update. Encodable
    /// stays synthesised — the on-disk shape always carries every field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        self.source = try c.decode(Source.self, forKey: .source)
        self.sourceFilename = try c.decodeIfPresent(String.self, forKey: .sourceFilename)
        self.audioFiles = try c.decode(AudioFiles.self, forKey: .audioFiles)
        self.speakers = try c.decode([Speaker].self, forKey: .speakers)
        self.summary = try c.decodeIfPresent(MeetingSummaryResult.self, forKey: .summary)
        self.meetingType = try c.decodeIfPresent(MeetingType.self, forKey: .meetingType) ?? .auto
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? MeetingMeta.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, durationSeconds, source, sourceFilename
        case audioFiles, speakers, summary, meetingType, schemaVersion
    }

    /// Default speaker palette used when a live meeting is created — only
    /// two entries because v0.1 doesn't diarize the remote side.
    static var defaultLiveSpeakers: [Speaker] {
        [
            Speaker(id: "me",    displayName: "Me",    colorHex: "#5B9BD5", isMe: true),
            Speaker(id: "other", displayName: "Other", colorHex: "#ED7D31", isMe: false),
        ]
    }

    /// Default speaker palette used for imports — single anonymous speaker.
    static var defaultImportSpeakers: [Speaker] {
        [Speaker(id: "other", displayName: "Other", colorHex: "#ED7D31", isMe: false)]
    }
}
