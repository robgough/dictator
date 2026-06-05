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
        /// True when `displayName` was set by the automatic speaker-name
        /// guess (`MeetingSpeakerNamer`) rather than the diarizer's default
        /// "Speaker N" or a manual rename. Lets re-runs overwrite a previous
        /// guess while still never clobbering a name the user typed, and lets
        /// the UI flag a name as auto-detected so it gets a second look.
        var nameInferred: Bool

        enum CodingKeys: String, CodingKey {
            case id, displayName, colorHex = "color", isMe, nameInferred
        }

        init(id: String, displayName: String, colorHex: String, isMe: Bool = false, nameInferred: Bool = false) {
            self.id = id
            self.displayName = displayName
            self.colorHex = colorHex
            self.isMe = isMe
            self.nameInferred = nameInferred
        }

        /// Backwards-compatible decode — `nameInferred` (and defensively
        /// `isMe`) fall back to false when missing, so speaker entries written
        /// before this field decode cleanly. Encode stays synthesised.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.displayName = try c.decode(String.self, forKey: .displayName)
            self.colorHex = try c.decode(String.self, forKey: .colorHex)
            self.isMe = try c.decodeIfPresent(Bool.self, forKey: .isMe) ?? false
            self.nameInferred = try c.decodeIfPresent(Bool.self, forKey: .nameInferred) ?? false
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
    /// Markdown meeting notes — the primary artifact. Present once the live
    /// first-pass (`isFinal == false`) or the end-of-meeting pass
    /// (`isFinal == true`) has run. New meetings populate this; older meetings
    /// that pre-date it decode as nil and fall back to `summary`.
    var notes: MeetingNotes?
    /// The rough first-pass notes built live during the recording, kept even
    /// after the full pass overwrites `notes`. The live pass accumulates as the
    /// meeting runs so it's often more complete (if less polished) than the
    /// compressed final rewrite — worth keeping around to compare against.
    var rawNotes: MeetingNotes?
    /// Legacy structured summary. Superseded by `notes` for new meetings, but
    /// kept so meetings recorded before the markdown-notes switch still render
    /// and export. Old meetings decode this; new meetings leave it nil.
    var summary: MeetingSummaryResult?
    /// Conversational shape of the meeting (1-on-1, stand-up, retro, or a
    /// user-defined custom type). Drives which notes template the summary
    /// pass compiles in. `.auto` lets the model decide from the transcript;
    /// older meta.json blobs that pre-date this field decode as `.auto`.
    /// Stored as a bare-string id so a since-deleted custom type still
    /// decodes — resolution happens in `MeetingTypeRegistry`.
    var meetingType: MeetingTypeID
    /// When the user last edited the speaker roster by hand (rename / merge).
    /// The notes panel compares this against `notes.generatedAt` to prompt a
    /// re-run — notes written before the edit still carry the old names.
    var speakersEditedAt: Date?
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
        notes: MeetingNotes? = nil,
        rawNotes: MeetingNotes? = nil,
        summary: MeetingSummaryResult? = nil,
        meetingType: MeetingTypeID = .auto,
        speakersEditedAt: Date? = nil,
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
        self.notes = notes
        self.rawNotes = rawNotes
        self.summary = summary
        self.meetingType = meetingType
        self.speakersEditedAt = speakersEditedAt
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
        self.notes = try c.decodeIfPresent(MeetingNotes.self, forKey: .notes)
        self.rawNotes = try c.decodeIfPresent(MeetingNotes.self, forKey: .rawNotes)
        self.summary = try c.decodeIfPresent(MeetingSummaryResult.self, forKey: .summary)
        self.meetingType = try c.decodeIfPresent(MeetingTypeID.self, forKey: .meetingType) ?? .auto
        self.speakersEditedAt = try c.decodeIfPresent(Date.self, forKey: .speakersEditedAt)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? MeetingMeta.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, durationSeconds, source, sourceFilename
        case audioFiles, speakers, notes, rawNotes, summary, meetingType, speakersEditedAt, schemaVersion
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
