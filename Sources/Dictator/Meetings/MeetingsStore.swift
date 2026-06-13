import Foundation
import Observation

/// Sidebar-facing enumeration of meetings on disk. Mirrors
/// `DictationHistory` in shape — `@MainActor @Observable` singleton, list
/// of lightweight metas (no transcripts), refresh-from-disk on demand.
///
/// Transcripts stay lazy: the detail view reads the JSON when a meeting is
/// selected. Avoids holding every transcript in memory for the lifetime of
/// the app.
@MainActor
@Observable
final class MeetingsStore {
    static let shared = MeetingsStore()

    /// Newest first.
    private(set) var metas: [MeetingMeta] = []

    private init() {
        refresh()
    }

    /// Re-scan the meetings root and replace the in-memory list. Cheap
    /// enough to run on every `MeetingsWindow.appear` — one JSON read per
    /// folder.
    func refresh() {
        let loaded = MeetingStorage.loadAllMetas()
        metas = loaded.sorted { $0.createdAt > $1.createdAt }
        applyAutoDeleteIfConfigured()
        applyAudioRetentionIfConfigured()
        // Re-encode any finished meeting still holding bulky PCM audio
        // (recorded before compaction shipped, or whose compaction was
        // interrupted). Internally once-per-launch and fully async — this
        // call is free on every subsequent refresh.
        MeetingAudioCompactor.shared.sweepOnce()
    }

    /// Look up by UUID for the detail pane.
    func meta(id: UUID) -> MeetingMeta? {
        metas.first(where: { $0.id == id })
    }

    /// Persist `meta` to disk and refresh the in-memory list.
    func upsert(_ meta: MeetingMeta) {
        try? MeetingStorage.writeMeta(meta)
        if let idx = metas.firstIndex(where: { $0.id == meta.id }) {
            metas[idx] = meta
        } else {
            metas.insert(meta, at: 0)
        }
    }

    /// Delete the meeting folder and drop it from the in-memory list.
    func delete(id: UUID) {
        MeetingStorage.deleteMeeting(id: id)
        metas.removeAll { $0.id == id }
    }

    /// Rewrite every speaker link from one person to another, in memory and
    /// on disk — the meetings half of a people-store merge, so the absorbed
    /// record's history follows the survivor instead of dangling. An open
    /// MeetingSession holds its own meta copy and could stomp this on its
    /// next write; merges happen from settings, so in practice that copy is
    /// stale-but-idle, and a re-link costs one rename anyway.
    func repointPerson(from sourceID: String, to targetID: String) {
        for idx in metas.indices {
            var changed = false
            for s in metas[idx].speakers.indices where metas[idx].speakers[s].personID == sourceID {
                metas[idx].speakers[s].personID = targetID
                changed = true
            }
            if changed {
                try? MeetingStorage.writeMeta(metas[idx])
            }
        }
    }

    /// Persist a meeting-type override for one meeting. Used by the
    /// "Summarise as ▾" picker on the transcript page — the picker
    /// updates the store (which writes meta.json) and the session's
    /// in-memory meta in lockstep, then kicks off a re-summary that
    /// reads the new type. Silent no-op for unknown ids or when the
    /// type is unchanged.
    func setMeetingType(id: UUID, type: MeetingTypeID) {
        guard let idx = metas.firstIndex(where: { $0.id == id }) else { return }
        guard metas[idx].meetingType != type else { return }
        metas[idx].meetingType = type
        try? MeetingStorage.writeMeta(metas[idx])
    }

    /// Apply the user's auto-delete policy. 0 = never.
    private func applyAutoDeleteIfConfigured() {
        let days = AppState.shared.settings.meetingAutoDeleteAfterDays
        guard days > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let toRemove = metas.filter { $0.createdAt < cutoff }
        for m in toRemove {
            MeetingStorage.deleteMeeting(id: m.id)
        }
        metas.removeAll { $0.createdAt < cutoff }
    }

    /// Apply the user's audio-only retention policy. 0 = never. Older
    /// meetings keep their transcript but lose their `.caf` files. Cheap
    /// to run on every refresh: we only touch meetings whose meta still
    /// claims at least one audio file, and only if they've aged past the
    /// cutoff.
    private func applyAudioRetentionIfConfigured() {
        let days = AppState.shared.settings.meetingAudioRetentionDays
        guard days > 0 else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        for (idx, m) in metas.enumerated() {
            guard m.createdAt < cutoff else { continue }
            guard m.audioFiles.mic != nil || m.audioFiles.system != nil else { continue }
            if let updated = MeetingStorage.pruneAudio(for: m.id) {
                metas[idx] = updated
            }
        }
    }
}
