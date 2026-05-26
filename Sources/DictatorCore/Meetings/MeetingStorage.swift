import Foundation

/// Path helpers + read/write shims for per-meeting folders. One folder per
/// meeting under `~/Library/Application Support/Dictator/Meetings/<uuid>/`
/// containing `mic.m4a`, `system.m4a`, `transcript.json`, `meta.json`.
///
/// Local to each Mac — meetings are big audio files, syncing them into a
/// shared folder would chew bandwidth and storage. Held alongside model
/// weights for that reason.
enum MeetingStorage {
    static let micFilename = "mic.m4a"
    static let systemFilename = "system.m4a"
    static let transcriptFilename = "transcript.json"
    static let metaFilename = "meta.json"

    /// Root for every meeting folder. Created on demand.
    static func meetingsRoot() -> URL {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = (base ?? fm.temporaryDirectory)
            .appendingPathComponent("Dictator/Meetings", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Folder for a specific meeting. Created on demand.
    static func folder(for id: UUID) -> URL {
        let dir = meetingsRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func micURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(micFilename)
    }

    static func systemURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(systemFilename)
    }

    static func metaURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(metaFilename)
    }

    static func transcriptURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(transcriptFilename)
    }

    static func writeMeta(_ meta: MeetingMeta) throws {
        let data = try jsonEncoder.encode(meta)
        try data.write(to: metaURL(for: meta.id), options: .atomic)
    }

    static func readMeta(at url: URL) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? jsonDecoder.decode(MeetingMeta.self, from: data)
    }

    static func writeTranscript(_ transcript: MeetingTranscript, for id: UUID) throws {
        let data = try jsonEncoder.encode(transcript)
        try data.write(to: transcriptURL(for: id), options: .atomic)
    }

    static func readTranscript(for id: UUID) -> MeetingTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL(for: id)) else { return nil }
        return try? jsonDecoder.decode(MeetingTranscript.self, from: data)
    }

    /// Enumerate every meeting folder on disk and return its meta. Folders
    /// without a parseable `meta.json` are silently skipped — they may be
    /// in-flight captures that crashed before the meta got written.
    static func loadAllMetas() -> [MeetingMeta] {
        let root = meetingsRoot()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { url -> MeetingMeta? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            return readMeta(at: url.appendingPathComponent(metaFilename))
        }
    }

    static func deleteMeeting(id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
