import AppKit
import Foundation
import Observation

/// Session-only "Demo mode" for Dictator Meetings: while it's on, every surface
/// that would show the user's own content — the meeting list and its search,
/// each meeting's notes / transcript / pad / coach, the Details inspector, the
/// People editor — shows `MeetingsDemoFixtures` instead, so a screen recording
/// or a screenshot can't leak a real call.
///
/// Four properties make it safe to leave in a shipping build:
///
/// - **Session-only.** `isOn` is in-memory and never persisted (deliberately
///   *not* a `MeetingsSettings` field). Quitting the app turns it off.
/// - **The real stores are never written.** Switching on doesn't touch the
///   synced `Meetings/` folder, the local audio folder, `people.json` or
///   settings. The fixtures are materialised into a throwaway folder under the
///   temp directory and `MeetingStorage` is told to resolve *those six ids* —
///   and only those — there (`MeetingStorage.demoRoot` / `demoIDs`). Every
///   read and write for a fixture meeting (transcript, pad, notes.md, speaker
///   rename, delete) therefore lands in the temp folder for free, because the
///   whole app already goes through `MeetingStorage.folder(for:)`.
/// - **A recording made during a demo is real.** Nothing here re-points global
///   storage, so pressing Record writes to the real synced folder and the real
///   audio folder exactly as normal. The new meeting has a fresh id, which is
///   not a fixture id, so none of the redirects apply to it — and
///   `meetings(real:)` merges anything created since `switchedOnAt` in on top
///   of the fixtures, so "record, stop, read the notes" works on camera.
/// - **Edits to fixtures stay in the demo.** Renaming or deleting a fixture
///   meeting, or a fixture person, changes the overlay (and the temp folder);
///   the same action on a real meeting made during the demo does the real
///   thing. Everything demo-side is thrown away on switch-off.
///
/// Live recording itself is deliberately NOT faked: the calendar-derived title
/// and attendees on a live capture are the user's own real call, and the coach
/// island is a live surface. Demo mode only stands in for *stored* content.
@MainActor
@Observable
final class MeetingsDemoMode {
    static let shared = MeetingsDemoMode()

    private(set) var isOn = false

    /// When the switch was flipped on. Real meetings newer than this are shown
    /// alongside the fixtures; older real meetings stay hidden.
    private(set) var switchedOnAt: Date?

    /// The fixtures, newest-first, as the list shows them. Rebuilt on every
    /// switch-on so the relative dates stay fresh, and cleared on switch-off so
    /// a second demo starts from a clean set.
    private var meetingOverlay: [MeetingMeta] = []
    private var peopleOverlay: [PersonRecord] = []

    /// Throwaway root the fixture meetings' files live under while demo mode is
    /// on — `/tmp/…/DictatorMeetingsDemo/<session uuid>/<meeting uuid>/`.
    private var sessionRoot: URL?

    private init() {}

    // MARK: - Switching

    func toggle() { setOn(!isOn) }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        if on { switchOn() } else { switchOff() }
        isOn = on
        NSLog("[DictatorMeetings] Demo mode \(on ? "on" : "off")")
    }

    private func switchOn() {
        switchedOnAt = Date()
        let metas = MeetingsDemoFixtures.metas()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictatorMeetingsDemo", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sessionRoot = root

        // Install the redirect BEFORE writing anything: every `MeetingStorage`
        // call below resolves through it, so not one fixture byte can reach the
        // user's real meetings folder.
        MeetingStorage.demoRoot = root
        MeetingStorage.demoIDs.formUnion(metas.map(\.id))

        let transcripts = MeetingsDemoFixtures.transcripts()
        let pads = MeetingsDemoFixtures.pads()
        for meta in metas {
            try? MeetingStorage.writeMeta(meta)
            if let transcript = transcripts[meta.id] {
                // Writes `transcript.json` and re-renders `transcript.md` from
                // the meta just written, exactly as a real meeting does.
                try? MeetingStorage.writeTranscript(transcript, for: meta.id)
            }
            if let pad = pads[meta.id] {
                try? MeetingStorage.writePad(pad, for: meta.id)
            }
        }

        meetingOverlay = metas.sorted { $0.createdAt > $1.createdAt }
        peopleOverlay = MeetingsDemoFixtures.people()
    }

    private func switchOff() {
        switchedOnAt = nil
        meetingOverlay = []
        peopleOverlay = []
        // The fixture files go; the REDIRECT deliberately stays. A view or a
        // debounced pad autosave can still fire against a fixture id a moment
        // after the switch goes off, and that write has to keep landing in the
        // temp folder rather than creating a stray folder in the user's real
        // meetings root. The ids are hardcoded and can never be a real
        // meeting's, so leaving them pointed at a throwaway path costs nothing;
        // the next switch-on repoints them at a fresh one.
        if let sessionRoot {
            try? FileManager.default.removeItem(at: sessionRoot)
        }
    }

    // MARK: - Meetings

    /// True when `id` is one of the fixtures currently being shown — i.e. when
    /// an edit or a delete must stay inside the demo.
    func isFixture(_ id: UUID) -> Bool {
        isOn && meetingOverlay.contains { $0.id == id }
    }

    /// The meeting list: the fixtures, plus any real meeting recorded or
    /// imported since the switch went on. Both sides are sorted newest-first
    /// and the fixtures are all in the past, so a meeting made during the demo
    /// lands at the top where the user expects it.
    func meetings(real: [MeetingMeta]) -> [MeetingMeta] {
        guard isOn, let since = switchedOnAt else { return real }
        return real.filter { $0.createdAt >= since } + meetingOverlay
    }

    /// Resolve by id for the detail pane, which is handed an id rather than a
    /// list. Falls back to the real meeting so one recorded during the demo
    /// still opens.
    func meta(id: UUID, real: MeetingMeta?) -> MeetingMeta? {
        if isOn, let fixture = meetingOverlay.first(where: { $0.id == id }) { return fixture }
        return real
    }

    /// A write-back from the detail pane (title edit, speaker rename, notes
    /// re-run). For a fixture it updates the overlay and the temp folder; for
    /// anything else it's the real store's job.
    func upsert(_ meta: MeetingMeta, real: () -> Void) {
        guard isFixture(meta.id) else { return real() }
        try? MeetingStorage.writeMeta(meta)   // redirected to the temp folder
        if let idx = meetingOverlay.firstIndex(where: { $0.id == meta.id }) {
            meetingOverlay[idx] = meta
        }
    }

    /// Deleting a fixture on camera drops it from the demo (and its temp
    /// folder); deleting a real meeting made during the demo does the real
    /// thing.
    func delete(id: UUID, real: () -> Void) {
        guard isFixture(id) else { return real() }
        MeetingStorage.deleteMeeting(id: id)  // redirected to the temp folder
        meetingOverlay.removeAll { $0.id == id }
        // The id stays in `MeetingStorage.demoIDs` on purpose — see
        // `switchOff()`: a late write against a deleted fixture must not be
        // able to fall through to the real meetings folder.
    }

    func setMeetingType(id: UUID, type: MeetingTypeID, real: () -> Void) {
        guard isFixture(id) else { return real() }
        guard let idx = meetingOverlay.firstIndex(where: { $0.id == id }),
              meetingOverlay[idx].meetingType != type else { return }
        meetingOverlay[idx].meetingType = type
        try? MeetingStorage.writeMeta(meetingOverlay[idx])
    }

    // MARK: - People

    /// Fixture people only — unlike meetings, nothing real is merged in. A
    /// person learned from a meeting recorded during the demo is a real
    /// colleague with a real name, which is exactly what mustn't be on screen.
    /// (The learning still happens: `PeopleStore` is untouched by all of this,
    /// so the real `people.json` gains them as normal.)
    func people(real: [PersonRecord]) -> [PersonRecord] {
        isOn ? peopleOverlay : real
    }

    func renamePerson(id: String, to name: String, real: () -> Void) {
        guard isOn, let idx = peopleOverlay.firstIndex(where: { $0.id == id }) else { return real() }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        peopleOverlay[idx].name = trimmed
        peopleOverlay[idx].updatedAt = Date()
    }

    func deletePerson(id: String, real: () -> Void) {
        guard isOn, peopleOverlay.contains(where: { $0.id == id }) else { return real() }
        peopleOverlay.removeAll { $0.id == id }
    }

    /// Merging two fixture people folds the overlay records together — and
    /// deliberately does NOT call `MeetingsStore.repointPerson`, which would
    /// rewrite every real `meta.json` on disk.
    func mergePeople(source sourceID: String, into targetID: String, real: () -> Void) {
        guard isOn,
              let source = peopleOverlay.first(where: { $0.id == sourceID }),
              let dst = peopleOverlay.firstIndex(where: { $0.id == targetID })
        else { return real() }
        for email in source.emails where !peopleOverlay[dst].emails.contains(email) {
            peopleOverlay[dst].emails.append(email)
        }
        peopleOverlay[dst].embeddings.append(contentsOf: source.embeddings)
        peopleOverlay[dst].updatedAt = Date()
        peopleOverlay.removeAll { $0.id == sourceID }
    }

    // MARK: - URL scheme

    /// Handles `dictator-meetings://demo`. `?on=1` (or `true`/`yes`) switches it
    /// on, `?on=0` (`false`/`no`) off, and no parameter at all toggles — so a
    /// recording script can do either.
    static func handleURL(_ url: URL) {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "on" })?
            .value?.trimmingCharacters(in: .whitespaces).lowercased()
        switch raw {
        case nil, "":                     shared.toggle()
        case "1", "true", "yes", "on":    shared.setOn(true)
        case "0", "false", "no", "off":   shared.setOn(false)
        default:
            NSLog("[DictatorMeetings] dictator-meetings://demo: unrecognised on=\(raw ?? "") — toggling")
            shared.toggle()
        }
    }
}
