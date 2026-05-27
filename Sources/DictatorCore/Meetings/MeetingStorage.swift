import Foundation

/// Path helpers + read/write shims for per-meeting folders. One folder per
/// meeting under `~/Library/Application Support/Dictator/Meetings/<uuid>/`
/// containing `mic.caf`, `system.caf`, `transcript.json`, `meta.json`.
///
/// We use CAF (LinearPCM) rather than compressed M4A for the audio tracks
/// because CAF is crash-safe by design: its data chunk uses a "-1 = read
/// to end" length sentinel, so a truncated CAF (from a Dictator crash or
/// power loss mid-recording) is fully decodable. M4A would lose the moov
/// atom on crash and the whole file becomes unreadable. The cost is disk:
/// ~700 MB/hour/track at Float32 mono 48 kHz.
///
/// Local to each Mac — meetings are big audio files, syncing them into a
/// shared folder would chew bandwidth and storage. Held alongside model
/// weights for that reason.
enum MeetingStorage {
    static let micFilename = "mic.caf"
    static let systemFilename = "system.caf"
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

    /// Remove just the audio (mic.caf, system.caf) for `id`, leaving
    /// meta.json + transcript.json in place. Used by the audio-retention
    /// sweep that ages out the bulky recordings while keeping the
    /// transcripts searchable forever.
    /// Returns the updated meta with `audioFiles` cleared, ready for the
    /// caller to persist. Returns nil if the meeting's meta couldn't be read.
    static func pruneAudio(for id: UUID) -> MeetingMeta? {
        let folder = folder(for: id)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(micFilename))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(systemFilename))
        guard var meta = readMeta(at: folder.appendingPathComponent(metaFilename)) else { return nil }
        meta.audioFiles = MeetingMeta.AudioFiles(mic: nil, system: nil)
        try? writeMeta(meta)
        return meta
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
