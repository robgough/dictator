import Foundation
@preconcurrency import AVFoundation

/// Recovers meetings whose recording was cut short by a crash.
///
/// A clean stop writes `meta.json` (and kicks off the post-pass) and finalises
/// `live.json` to `status: stopped`; a crash mid-recording reaches neither, so
/// the meeting folder is left holding a `live.json` still reading `recording`
/// but **no `meta.json`** — invisible to `MeetingsStore`, and stuck advertising
/// an in-progress recording. Because `live.json` is written from the first
/// moment of recording, `live.json`-without-`meta.json` is a precise marker for
/// "a recording crashed here".
///
/// At launch we find those folders and synthesise the `meta.json` the crash
/// skipped — folding in the first-pass notes mirrored to `live-notes.md`, and
/// the audio tracks left on disk. The meeting then surfaces as a normal
/// `.captured` meeting (`MeetingSession.init(from:)` lands it there with a
/// "Process now" button), so the user finishes it exactly as if they'd stopped
/// it by hand. `live.json`'s `status` is flipped to `interrupted` so nothing is
/// left advertising a live recording.
///
/// We only recover a folder whose **audio is on this Mac**. Meeting text syncs
/// across Macs but audio stays local, so a `live.json`-without-`meta.json` with
/// no local audio belongs to a recording another synced Mac made (and will
/// recover itself, the `meta.json` then syncing here) — synthesising a meta for
/// it from this machine would wrongly record it as audio-less. Idempotent —
/// folders that already have `meta.json` are skipped — so it's safe to run on
/// every launch, in `AppState.bootstrap` after the synced path is set and
/// before `MeetingsStore` first scans.
@MainActor
enum MeetingRecovery {
    /// Scan for and recover every interrupted recording. Returns the recovered
    /// ids (for logging); callers can ignore the result.
    @discardableResult
    static func recoverInterrupted(settings: DictatorSettings) -> [UUID] {
        let fm = FileManager.default
        let root = MeetingStorage.meetingsRoot()
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var recovered: [UUID] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            // A live.json marks a recording; a meta.json means it already
            // stopped cleanly (or was recovered). Only the former-without-latter
            // is an interrupted recording.
            guard fm.fileExists(atPath: MeetingStorage.liveStateURL(for: id).path),
                  !fm.fileExists(atPath: MeetingStorage.metaURL(for: id).path) else { continue }
            if recoverOne(id: id, settings: settings) { recovered.append(id) }
        }
        if !recovered.isEmpty {
            NSLog("[Dictator] Recovered \(recovered.count) interrupted meeting(s)")
        }
        return recovered
    }

    /// Recover a single interrupted folder. Returns true if a meeting was
    /// created (false when the recording's audio isn't on this Mac).
    private static func recoverOne(id: UUID, settings: DictatorSettings) -> Bool {
        let micDuration = audioDuration(MeetingStorage.micURL(for: id))
        let systemDuration = audioDuration(MeetingStorage.systemURL(for: id))
        let micPresent = micDuration != nil
        let systemPresent = systemDuration != nil

        // No local audio → not this Mac's recording to recover (see type doc).
        guard micPresent || systemPresent else { return false }

        let liveNotes = (try? String(contentsOf: MeetingStorage.liveNotesURL(for: id), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let createdAt = readStartedAt(for: id)
            ?? earliestCreationDate(of: [MeetingStorage.micURL(for: id), MeetingStorage.systemURL(for: id)])
            ?? Date()

        var meta = MeetingMeta(
            id: id,
            title: defaultTitle(for: createdAt),
            createdAt: createdAt,
            durationSeconds: max(micDuration ?? 0, systemDuration ?? 0),
            source: .live,
            audioFiles: .init(
                mic: micPresent ? MeetingStorage.micFilename : nil,
                system: systemPresent ? MeetingStorage.systemFilename : nil
            ),
            speakers: MeetingMeta.defaultLiveSpeakers
        )

        if !liveNotes.isEmpty {
            let notes = MeetingNotes(
                markdown: liveNotes,
                modelID: MeetingSummaryService.engineModelID(settings: settings),
                generatedAt: createdAt,
                isFinal: false
            )
            meta.notes = notes
            meta.rawNotes = notes
        }

        try? MeetingStorage.writeMeta(meta)
        // Clear the stale `recording` status now there's a meta.json; the live
        // files stay as the meeting's first-pass record.
        MeetingStorage.finalizeLiveState(status: "interrupted", for: id)
        return true
    }

    // MARK: - Helpers

    /// The recording's start time as recorded in `live.json`, if parseable —
    /// more accurate than the audio file's creation date.
    private static func readStartedAt(for id: UUID) -> Date? {
        guard let data = try? Data(contentsOf: MeetingStorage.liveStateURL(for: id)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let started = obj["startedAt"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: started)
    }

    /// Duration of an audio file in seconds, or nil if it's missing, empty, or
    /// unreadable. Opening only reads the header, so this is cheap even for a
    /// multi-hundred-MB PCM track. A CAF truncated by the crash still opens —
    /// its data chunk uses a read-to-end length sentinel by design.
    private static func audioDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    private static func earliestCreationDate(of urls: [URL]) -> Date? {
        urls.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.min()
    }

    /// Mirrors `MeetingSession.defaultTitle` exactly so the recovered title is
    /// recognised by `MeetingSummaryService.isDefaultMeetingTitle` and gets
    /// auto-renamed when the user processes the meeting.
    private static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting on \(f.string(from: date))"
    }
}
