import Foundation

/// Path helpers + read/write shims for meetings. A meeting is split across two
/// locations:
///
///   - **Synced** (`meetingsRoot()` → `<synced folder>/Meetings/<uuid>/`):
///     `meta.json` + `transcript.json`. Small, so they ride the same synced
///     folder as settings / vocabulary / history (`SyncedStorage`) and a
///     meeting recorded on one Mac can be read on another.
///   - **Local** (`audioRoot()` → `~/Library/Application Support/Dictator/
///     Meetings/<uuid>/`): `mic.caf` + `system.caf`. Audio is large, so it
///     stays per-Mac and never syncs. A Mac that didn't do the recording
///     just shows the notes + transcript without playback —
///     `MeetingSession.init(from:)` already copes with absent audio.
///
/// We use CAF rather than M4A for the audio tracks because CAF is crash-safe
/// by design: its data chunk uses a "-1 = read to end" length sentinel, so a
/// truncated CAF (from a Dictator crash or power loss mid-recording) is fully
/// decodable. M4A would lose the moov atom on crash and the whole file
/// becomes unreadable.
///
/// The *payload* inside the `.caf` varies over a meeting's life: live
/// recordings are captured as LinearPCM Int16 mono (~350 MB/hour/track at
/// 48 kHz — dumb, fast, decodable when truncated), then once the post-pass
/// has the transcript `MeetingAudioCompactor` re-encodes each track in place
/// to mono AAC (~40 MB/hour) under the same filename. Imports are written as
/// AAC from the start. Consumers never need to care which they're holding —
/// `AVAudioFile` / `AVAudioPlayer` read both transparently — so
/// `meta.audioFiles` works as a plain presence flag throughout.
enum MeetingStorage {
    static let micFilename = "mic.caf"
    static let systemFilename = "system.caf"
    static let transcriptFilename = "transcript.json"
    static let tracksFilename = "tracks.json"
    static let metaFilename = "meta.json"
    static let padFilename = "pad.md"

    /// Base folder the synced text files live under (a `Meetings/` subfolder is
    /// appended). Set once during `AppState.bootstrap` from
    /// `SyncedStorage.directory`, and refreshed on settings save so a folder
    /// change takes new meetings with it. nil → falls back to the local audio
    /// root (so on iOS / before bootstrap everything is in one place).
    /// `nonisolated(unsafe)` because `meetingsRoot()` is nonisolated and called
    /// from several contexts: assigned once on the main actor before any
    /// meeting I/O, then only read.
    nonisolated(unsafe) static var syncedBaseURL: URL?

    /// The per-Mac Application Support base for `Dictator/Meetings`. Audio
    /// always lives here; when no synced folder is configured, the synced text
    /// files collapse onto it too.
    private static func appSupportMeetingsRoot() -> URL {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return (base ?? fm.temporaryDirectory)
            .appendingPathComponent("Dictator/Meetings", isDirectory: true)
    }

    /// Root for the synced per-meeting folders (meta.json, transcript.json).
    static func meetingsRoot() -> URL {
        let fm = FileManager.default
        let dir: URL
        if let syncedBaseURL {
            dir = syncedBaseURL.appendingPathComponent("Meetings", isDirectory: true)
        } else {
            dir = appSupportMeetingsRoot()
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Root for the local per-meeting audio folders (mic.caf, system.caf).
    /// Always per-Mac — never synced.
    static func audioRoot() -> URL {
        let dir = appSupportMeetingsRoot()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Synced folder for a specific meeting (meta + transcript). Created on demand.
    static func folder(for id: UUID) -> URL {
        let dir = meetingsRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Local folder for a specific meeting's audio tracks. Created on demand.
    static func audioFolder(for id: UUID) -> URL {
        let dir = audioRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func micURL(for id: UUID) -> URL {
        audioFolder(for: id).appendingPathComponent(micFilename)
    }

    static func systemURL(for id: UUID) -> URL {
        audioFolder(for: id).appendingPathComponent(systemFilename)
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

    static func tracksURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(tracksFilename)
    }

    /// The user's own notes for a meeting — the "pad" they type into while
    /// (or after) recording. Markdown-native, so it lives as a plain `pad.md`
    /// beside meta.json in the synced folder rather than a field inside it:
    /// human-readable in Finder, cheap to autosave on every debounce tick,
    /// and it rides the same sync as the rest of the meeting's text.
    static func padURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(padFilename)
    }

    /// Empty string when the meeting has no pad — callers treat "" as absent.
    static func readPad(for id: UUID) -> String {
        (try? String(contentsOf: padURL(for: id), encoding: .utf8)) ?? ""
    }

    /// Writes the pad, removing the file entirely when the text is blank so
    /// an emptied pad doesn't leave a stray zero-content pad.md behind.
    static func writePad(_ text: String, for id: UUID) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: padURL(for: id))
        } else {
            try text.write(to: padURL(for: id), atomically: true, encoding: .utf8)
        }
    }

    static func writeTrackInspection(_ inspection: MeetingTrackInspection, for id: UUID) throws {
        let data = try jsonEncoder.encode(inspection)
        try data.write(to: tracksURL(for: id), options: .atomic)
    }

    static func readTrackInspection(for id: UUID) -> MeetingTrackInspection? {
        guard let data = try? Data(contentsOf: tracksURL(for: id)) else { return nil }
        return try? jsonDecoder.decode(MeetingTrackInspection.self, from: data)
    }

    /// Enumerate every synced meeting folder and return its meta. Folders
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
        try? FileManager.default.removeItem(at: folder(for: id))       // synced meta + transcript
        try? FileManager.default.removeItem(at: audioFolder(for: id))  // local audio
    }

    /// Remove just the audio (mic.caf, system.caf) for `id`, leaving
    /// meta.json + transcript.json in place. Used by the audio-retention
    /// sweep that ages out the bulky recordings while keeping the
    /// transcripts searchable forever.
    /// Returns the updated meta with `audioFiles` cleared, ready for the
    /// caller to persist. Returns nil if the meeting's meta couldn't be read.
    static func pruneAudio(for id: UUID) -> MeetingMeta? {
        let audio = audioFolder(for: id)
        try? FileManager.default.removeItem(at: audio.appendingPathComponent(micFilename))
        try? FileManager.default.removeItem(at: audio.appendingPathComponent(systemFilename))
        guard var meta = readMeta(at: metaURL(for: id)) else { return nil }
        meta.audioFiles = MeetingMeta.AudioFiles(mic: nil, system: nil)
        try? writeMeta(meta)
        return meta
    }

    /// Reconcile on-disk meetings with the split (synced text / local audio)
    /// layout. Idempotent, run once at bootstrap:
    ///
    ///  1. Pulls any `*.caf` that ended up in the synced folder back out into
    ///     the local audio root — covers an earlier build that synced the whole
    ///     meeting folder — so the big audio files stop syncing (and iCloud
    ///     drops its copies). A same-volume move is instant regardless of size.
    ///  2. For any meeting still living entirely in the local Application
    ///     Support folder (audio + text together, never synced), copies its
    ///     `meta.json` + `transcript.json` up into the synced root; the audio
    ///     stays put.
    static func migrateToSplitStorage() {
        let fm = FileManager.default
        let synced = meetingsRoot()
        let audio = audioRoot()

        // 1) Audio sitting in the synced folder → move it back to local.
        if let entries = try? fm.contentsOfDirectory(
            at: synced, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let id = dir.lastPathComponent
                for name in [micFilename, systemFilename] {
                    let src = dir.appendingPathComponent(name)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let destDir = audio.appendingPathComponent(id, isDirectory: true)
                    try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    let dst = destDir.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        // Already have it locally — just drop the synced copy.
                        try? fm.removeItem(at: src)
                    } else {
                        do { try fm.moveItem(at: src, to: dst) }
                        catch { NSLog("[Dictator] Couldn't move \(name) for \(id) out of the synced folder: \(error)") }
                    }
                }
            }
        }

        // 2) Meetings still entirely in App Support → copy text up to synced.
        guard synced.standardizedFileURL != audio.standardizedFileURL else { return }
        if let entries = try? fm.contentsOfDirectory(
            at: audio, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let id = dir.lastPathComponent
                let syncedDir = synced.appendingPathComponent(id, isDirectory: true)
                for name in [metaFilename, transcriptFilename] {
                    let src = dir.appendingPathComponent(name)
                    let dst = syncedDir.appendingPathComponent(name)
                    guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
                    try? fm.createDirectory(at: syncedDir, withIntermediateDirectories: true)
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }
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
