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
    static let notesFilename = "notes.md"
    static let transcriptMarkdownFilename = "transcript.md"
    static let liveNotesFilename = "live-notes.md"
    static let liveTranscriptFilename = "live-transcript.md"
    static let liveStateFilename = "live.json"

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

    static let screenshotsFolderName = "screenshots"
    static let screenshotIndexFilename = "index.json"

    /// Local folder for a meeting's captured screen keyframes (HEICs + their
    /// `index.json`). Sits under the per-Mac audio folder — the frames are
    /// large-ish and per-machine like the audio, never synced. Folder removal
    /// in `deleteMeeting` / auto-delete already covers them (they're inside
    /// `audioFolder`).
    static func screenshotsFolder(for id: UUID) -> URL {
        let dir = audioFolder(for: id).appendingPathComponent(screenshotsFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func screenshotIndexURL(for id: UUID) -> URL {
        screenshotsFolder(for: id).appendingPathComponent(screenshotIndexFilename)
    }

    static func readScreenshotIndex(for id: UUID) -> MeetingScreenshotIndex? {
        guard let data = try? Data(contentsOf: screenshotIndexURL(for: id)),
              let index = try? jsonDecoder.decode(MeetingScreenshotIndex.self, from: data),
              !index.screenshots.isEmpty else { return nil }
        return index
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
        // Mirror the prose to readable `notes.md` / `transcript.md` beside
        // meta.json. The JSON files stay the source of truth (they're what the
        // app renders, searches, and edits in memory, and `transcript.json`
        // carries word timings + diarization the markdown can't); these are
        // derived, human-/tool-readable copies kept in lockstep by riding the
        // single meta write path — speaker renames here re-render the transcript
        // markdown too. Best-effort: a failure must not fail the real write.
        writeNotesMarkdown(for: meta)
        if let transcript = readTranscript(for: meta.id) {
            writeTranscriptMarkdown(transcript, meta: meta)
        }
    }

    static func notesMarkdownURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(notesFilename)
    }

    static func transcriptMarkdownURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(transcriptMarkdownFilename)
    }

    /// Write `notes.md` from the meeting's current notes, or remove it when
    /// there are none. The meeting title is prefixed as an H1 (the notes body
    /// itself starts at `## Summary`) so the file reads as a standalone document
    /// — matching how the app copies/exports notes.
    private static func writeNotesMarkdown(for meta: MeetingMeta) {
        let url = notesMarkdownURL(for: meta.id)
        let body = meta.notes?.markdown.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? "# \(meta.title)\n\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Write `transcript.md` — the diarized transcript rendered as readable
    /// markdown (the canonical structured form, with word timings + speaker
    /// segments, stays in `transcript.json`). Speaker names + title come from
    /// `meta`, so this is re-rendered both when the transcript is written and on
    /// any later meta change (e.g. a speaker rename).
    private static func writeTranscriptMarkdown(_ transcript: MeetingTranscript, meta: MeetingMeta) {
        let md = MeetingExporter.transcriptMarkdown(transcript: transcript, meta: meta)
        try? md.write(to: transcriptMarkdownURL(for: meta.id), atomically: true, encoding: .utf8)
    }

    /// Ensure every meeting's derived markdown (`notes.md`, `transcript.md`)
    /// exists — backfills meetings recorded before these files existed. Cheap
    /// and idempotent (writes only the missing ones), so it's safe to run once
    /// at bootstrap on every launch.
    static func backfillDerivedMarkdown() {
        let fm = FileManager.default
        for meta in loadAllMetas() {
            if meta.notes?.markdown.isEmpty == false,
               !fm.fileExists(atPath: notesMarkdownURL(for: meta.id).path) {
                writeNotesMarkdown(for: meta)
            }
            if !fm.fileExists(atPath: transcriptMarkdownURL(for: meta.id).path),
               let transcript = readTranscript(for: meta.id) {
                writeTranscriptMarkdown(transcript, meta: meta)
            }
        }
    }

    static func readMeta(at url: URL) -> MeetingMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? jsonDecoder.decode(MeetingMeta.self, from: data)
    }

    static func writeTranscript(_ transcript: MeetingTranscript, for id: UUID) throws {
        let data = try jsonEncoder.encode(transcript)
        try data.write(to: transcriptURL(for: id), options: .atomic)
        // Refresh the readable transcript.md alongside (needs meta for speaker
        // names + title). Best-effort; transcript.json is the source of truth.
        if let meta = readMeta(at: metaURL(for: id)) {
            writeTranscriptMarkdown(transcript, meta: meta)
        }
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
    /// Crash-safety snapshot of the live coach checklist. LOCAL (audio
    /// folder, per-Mac) and transient — deleted once the outcomes fold into
    /// meta.coach after processing. Never one of the markdown mirrors.
    static func coachLiveURL(for id: UUID) -> URL {
        audioFolder(for: id).appendingPathComponent("coach-live.json")
    }

    static func writeCoachLive(_ state: MeetingCoachLiveState, for id: UUID) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: coachLiveURL(for: id), options: .atomic)
    }

    static func readCoachLive(for id: UUID) -> MeetingCoachLiveState? {
        guard let data = try? Data(contentsOf: coachLiveURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(MeetingCoachLiveState.self, from: data)
    }

    static func deleteCoachLive(for id: UUID) {
        try? FileManager.default.removeItem(at: coachLiveURL(for: id))
    }

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

    // MARK: - Live mirror (in-progress recording)
    //
    // While a meeting is recording, the live first-pass notes and the rolling
    // live transcript are mirrored to plain files refreshed every few seconds,
    // so an external tool (e.g. a meeting-coaching app) can read the meeting as
    // it takes shape, and so a crash mid-recording leaves the work on disk
    // rather than only in memory. They sit in the **synced** meeting folder
    // beside `meta.json` / `pad.md`, so a meeting's text all lives in one place
    // and a reader watching that folder finds both the live view and (later) the
    // canonical output. `live.json` is structured-only (status, timings, the
    // outline groups, the transcript lines); the prose lives in the two `.md`
    // files, never duplicated into the JSON.
    //
    // They are NOT deleted on stop: the final write sets `status` to `stopped`
    // (or `interrupted`), which is the signal a reader uses to switch over to
    // the polished `meta.json` / `transcript.json`. Note `live-transcript.md` is
    // the coarse Me/Them live pass — after processing, `transcript.json` is the
    // canonical, diarized one; the `live-` prefix and `status` mark these as the
    // first-pass view, not the authoritative record.
    //
    // Because `live.json` is written from the first moment of recording and only
    // a clean/interrupted stop finalises its `status`, a folder holding a
    // `live.json` but no `meta.json` is exactly a recording a crash cut short —
    // which is how `MeetingRecovery` finds them.
    //
    // The `live.json` schema is consumed by out-of-process readers; treat it as
    // a stable contract and version it (`MeetingLiveMirror.schemaVersion`).

    static func liveNotesURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(liveNotesFilename)
    }

    static func liveTranscriptURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(liveTranscriptFilename)
    }

    static func liveStateURL(for id: UUID) -> URL {
        folder(for: id).appendingPathComponent(liveStateFilename)
    }

    /// Refresh all three live-mirror artefacts for an in-progress meeting.
    /// `state` is the structured snapshot (generic so the concrete type can
    /// live in the app target without Core depending on it). Markdown files are
    /// written first and the JSON state last, so a reader that keys off the
    /// JSON's `updatedAt` and then reads the markdown sees a consistent set.
    static func writeLiveMirror<State: Encodable>(
        notesMarkdown: String,
        transcriptMarkdown: String,
        state: State,
        for id: UUID
    ) throws {
        let dir = folder(for: id)
        let stateData = try jsonEncoder.encode(state)
        try notesMarkdown.write(to: dir.appendingPathComponent(liveNotesFilename), atomically: true, encoding: .utf8)
        try transcriptMarkdown.write(to: dir.appendingPathComponent(liveTranscriptFilename), atomically: true, encoding: .utf8)
        try stateData.write(to: dir.appendingPathComponent(liveStateFilename), options: .atomic)
    }

    /// Patch just the `status` (and `updatedAt`) of an existing `live.json`,
    /// leaving the `.md` files untouched. Used by recovery to clear a crashed
    /// recording's stale `recording` status without the live producers around
    /// to rebuild a full snapshot. No-op if there's no parseable `live.json`.
    static func finalizeLiveState(status: String, for id: UUID) {
        let url = liveStateURL(for: id)
        guard let data = try? Data(contentsOf: url),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        obj["status"] = status
        obj["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? out.write(to: url, options: .atomic)
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
