import Foundation

/// One captured keyframe of shared screen content during a meeting. Stored in
/// the meeting's LOCAL folder (`screenshots/index.json` beside the HEICs) — the
/// frames are per-Mac like the audio, never synced.
struct ScreenshotRecord: Codable, Equatable, Identifiable, Sendable {
    /// File name within the meeting's `screenshots/` folder, e.g.
    /// `0007-00h23m12s.heic`. Doubles as the stable identity.
    var filename: String
    /// Seconds from the start of recording — pins the frame to the transcript
    /// timeline so a click can seek the player there.
    var offsetSeconds: Double
    /// Hex of the 64-bit average hash that earned this frame a keep, kept so a
    /// later dedup/inspection pass can reason about how distinct it was.
    var hash: String
    var capturedAt: Date
    /// OCR'd text, filled in by the post-meeting Vision pass (v2). nil until
    /// then; the capture pipeline doesn't OCR inline.
    var ocrText: String?

    var id: String { filename }
}

/// `screenshots/index.json` — the ordered keyframe list for one meeting. Small
/// (a handful of records), versioned because out-of-process readers and a v2
/// OCR pass both touch it.
struct MeetingScreenshotIndex: Codable, Equatable, Sendable {
    var screenshots: [ScreenshotRecord]
    var schemaVersion: Int

    static let currentSchemaVersion = 1

    init(screenshots: [ScreenshotRecord] = [], schemaVersion: Int = MeetingScreenshotIndex.currentSchemaVersion) {
        self.screenshots = screenshots
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.screenshots = try c.decodeIfPresent([ScreenshotRecord].self, forKey: .screenshots) ?? []
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
    }

    private enum CodingKeys: String, CodingKey { case screenshots, schemaVersion }
}
