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
}
