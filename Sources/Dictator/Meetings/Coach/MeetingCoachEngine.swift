import Foundation
import Observation

/// What the pre-record sheet hands the session: the chosen meeting type's
/// coach config, the layered client profiles, and the (user-edited) merged
/// checklist. nil plan = no preset chosen — behavioural nudges only.
struct CoachSessionPlan: Sendable {
    var typeID: String?
    var profileIDs: [String]
    /// (text, source) in display order — preset items, then profile items.
    var checklist: [(text: String, source: CoachChecklistEntry.Source)]
    var armedNudges: Set<CoachNudge.Kind>

    init(
        typeID: String? = nil,
        profileIDs: [String] = [],
        checklist: [(text: String, source: CoachChecklistEntry.Source)] = [],
        armedNudges: Set<CoachNudge.Kind> = CoachNudge.defaultArmed
    ) {
        self.typeID = typeID
        self.profileIDs = profileIDs
        self.checklist = checklist
        self.armedNudges = armedNudges
    }
}

/// One live checklist item. `id` is stable for the meeting's duration so
/// SwiftUI rows keep identity and the watcher's numbered references map back.
struct CoachChecklistEntry: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable { case preset, profile, adhoc }
    enum Status: Equatable, Sendable {
        case pending
        case done(atSeconds: Double)
        case dismissed
    }

    let id: String
    var text: String
    let source: Source
    /// Seconds into the meeting it was added (0 = pre-meeting).
    let addedAtSeconds: Double
    /// Transcript-line count when added — the watcher only matches this item
    /// against lines committed AFTER this, so something said at minute 5
    /// can't tick a reminder created at minute 30.
    let eligibleFromLine: Int
    var status: Status

    var isPending: Bool { status == .pending }
}

/// Owns the coach's live state for ONE recording. Constructed by
/// `MeetingSession` alongside the notes accumulator, fed from the recorders'
/// existing level callbacks and the live transcriber's committed lines, and
/// torn down with the recording.
///
/// Observation discipline (the `lastSystemLevel` lesson from
/// `MeetingSession`): level ingest happens ~100×/s and writes ONLY
/// `@ObservationIgnored` state — nothing observable mutates on the hot path.
/// A 1 Hz loop publishes `snapshot`/`activeNudge`; checklist mutations are
/// user/watcher-paced and publish immediately.
@MainActor
@Observable
final class MeetingCoachEngine {
    /// The published signals — talk share, monologue timer, pace, etc.
    private(set) var snapshot = MeetingCoachSignals.Snapshot()

    /// The nudge currently on display, if any. Set when a rule fires,
    /// cleared automatically after `nudgeDisplaySeconds` — the island
    /// expands while this is non-nil and shrinks back when it clears.
    private(set) var activeNudge: CoachNudge?

    /// The meeting's checklist — preset + profile items seeded at start,
    /// ad-hoc items appended live. Observable: the island and live pane
    /// render rows off it.
    private(set) var checklist: [CoachChecklistEntry] = []

    /// "Hide for this meeting" — set from the island's context menu. The
    /// island controller observes this; signals keep computing regardless
    /// (the post-meeting metrics don't stop because the strip is hidden).
    var chipHidden = false

    /// Plan context, carried into the final outcomes.
    let presetTypeID: String?
    let profileIDs: [String]

    /// Where the meeting's SCHEDULED end falls on this engine's elapsed
    /// clock, set when the calendar match lands. Unlocks the "wrapping up
    /// with key points open" nudge; nil (no calendar match) leaves that
    /// rule disarmed.
    @ObservationIgnored var scheduledEndElapsedSeconds: Double?

    /// Fired (debounced upstream by the caller) whenever checklist state
    /// changes, so the session can crash-mirror it to coach-live.json.
    @ObservationIgnored var onChecklistChanged: (() -> Void)?

    @ObservationIgnored private let signals = MeetingCoachSignals()
    @ObservationIgnored private let nudger: MeetingCoachNudger
    @ObservationIgnored private var nudgeClearAt: Date?
    @ObservationIgnored private static let nudgeDisplaySeconds: TimeInterval = 8
    @ObservationIgnored private weak var transcriber: MeetingLiveTranscriber?
    @ObservationIgnored private var consumedLineCount = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var adhocCounter = 0

    /// `transcriber` is nil when the live transcript is disabled — the coach
    /// still runs on levels alone (talk balance, monologues, interruptions);
    /// only the text-derived signals (pace, fillers, questions) and the
    /// checklist watcher stay quiet.
    init(transcriber: MeetingLiveTranscriber?, plan: CoachSessionPlan?) {
        self.transcriber = transcriber
        self.presetTypeID = plan?.typeID
        self.profileIDs = plan?.profileIDs ?? []
        self.nudger = MeetingCoachNudger(armed: plan?.armedNudges ?? CoachNudge.defaultArmed)
        if let plan {
            self.checklist = plan.checklist.enumerated().map { idx, item in
                CoachChecklistEntry(
                    id: "\(item.source.rawValue)-\(idx)",
                    text: item.text,
                    source: item.source,
                    addedAtSeconds: 0,
                    eligibleFromLine: 0,
                    status: .pending
                )
            }
        }
    }

    var hasChecklist: Bool { !checklist.isEmpty }

    /// Begin the clock + the 1 Hz publish loop. Called from the recorder's
    /// onReady (when capture actually starts), so t=0 is real audio time.
    func start() {
        guard loopTask == nil else { return }
        startedAt = Date()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                self.tick()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        startedAt = nil
    }

    /// Seconds since recording started; 0 before start.
    var elapsedSeconds: Double {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Checklist

    /// Add an ad-hoc item mid-meeting ("oh — I need to remember to say X").
    /// Tracked like any checklist item, plus it arms the reminder nudge.
    func addAdHocItem(_ text: String) {
        add(texts: [text], source: .adhoc)
    }

    /// Bulk-add (from a built-in set, a saved profile, or a pasted list).
    /// Lines are cleaned of markdown list markers, blanks dropped, and
    /// items already on the checklist (case-insensitive) skipped.
    func add(texts: [String], source: CoachChecklistEntry.Source) {
        let existing = Set(checklist.map { $0.text.lowercased() })
        var added = false
        var seen = existing
        for raw in texts {
            let cleaned = Self.cleanItemText(raw)
            guard !cleaned.isEmpty, !seen.contains(cleaned.lowercased()) else { continue }
            seen.insert(cleaned.lowercased())
            adhocCounter += 1
            checklist.append(CoachChecklistEntry(
                id: "\(source.rawValue)-\(adhocCounter)",
                text: cleaned,
                source: source,
                addedAtSeconds: elapsedSeconds,
                eligibleFromLine: transcriber?.transcriptLines.count ?? 0,
                status: .pending
            ))
            added = true
        }
        if added { onChecklistChanged?() }
    }

    /// Arm additional nudges mid-meeting — adding a key-point set arms that
    /// set's nudges (a discovery checklist without the ask-question nudge
    /// is half a set). Additive; nothing de-arms.
    func armNudges(_ rawKinds: [String]) {
        let kinds = Set(rawKinds.compactMap(CoachNudge.Kind.init(rawValue:)))
        guard !kinds.isEmpty else { return }
        nudger.arm(kinds)
    }

    /// Strip markdown list furniture so a pasted `- [ ] Ask about budget`
    /// lands as `Ask about budget` — leading bullets (`-`, `*`, `+`, `•`),
    /// checkbox brackets, and `1.` / `1)` numbering.
    static func cleanItemText(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for marker in ["- ", "* ", "+ ", "• ", "– "] where t.hasPrefix(marker) {
                t = String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            for box in ["[ ]", "[x]", "[X]"] where t.hasPrefix(box) {
                t = String(t.dropFirst(box.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
            // `1.` / `12)` numbering.
            let digits = t.prefix(while: \.isNumber)
            if !digits.isEmpty, t.count > digits.count {
                let after = t[t.index(t.startIndex, offsetBy: digits.count)]
                if after == "." || after == ")" {
                    t = String(t.dropFirst(digits.count + 1)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }
        return t
    }

    /// "Never mind" — the item leaves the pending set and the scorecard
    /// records it as dismissed, not missed. Also how a manual tick works
    /// (toggle to done) — see `toggleDone`.
    func dismissItem(id: String) {
        guard let idx = checklist.firstIndex(where: { $0.id == id }) else { return }
        checklist[idx].status = .dismissed
        onChecklistChanged?()
    }

    /// Manual tick/untick from the UI.
    func toggleDone(id: String) {
        guard let idx = checklist.firstIndex(where: { $0.id == id }) else { return }
        switch checklist[idx].status {
        case .done: checklist[idx].status = .pending
        case .pending, .dismissed: checklist[idx].status = .done(atSeconds: elapsedSeconds)
        }
        onChecklistChanged?()
    }

    /// Watcher verdicts: mark items addressed. Monotonic — the watcher can
    /// only tick, never untick (only the user can, manually).
    func markDone(ids: [String]) {
        var changed = false
        for id in ids {
            guard let idx = checklist.firstIndex(where: { $0.id == id }),
                  checklist[idx].isPending else { continue }
            checklist[idx].status = .done(atSeconds: elapsedSeconds)
            changed = true
        }
        if changed { onChecklistChanged?() }
    }

    /// Pending items eligible for watcher matching given the transcript
    /// cursor — an item only matches lines committed after it was added.
    func watchableItems(beforeLine cursor: Int) -> [CoachChecklistEntry] {
        checklist.filter { $0.isPending && $0.eligibleFromLine <= cursor }
    }

    /// Final state for `meta.coach`, captured at stop.
    func outcomes() -> [CoachChecklistOutcome] {
        checklist.map { entry in
            let doneAt: Double? = {
                if case .done(let at) = entry.status { return at }
                return nil
            }()
            return CoachChecklistOutcome(
                source: entry.source.rawValue,
                text: entry.text,
                addedAtSeconds: entry.addedAtSeconds,
                doneAtSeconds: doneAt,
                dismissed: entry.status == .dismissed
            )
        }
    }

    // MARK: - Ingest

    /// Both recorders' onLevel closures land on the main actor (they already
    /// write `MeetingSession`'s private level stashes), so plain calls here.
    func ingestMicLevel(_ level: Float) {
        guard let startedAt else { return }
        signals.ingestMic(level: level, at: Date().timeIntervalSince(startedAt))
    }

    func ingestSystemLevel(_ level: Float) {
        guard let startedAt else { return }
        signals.ingestSystem(level: level, at: Date().timeIntervalSince(startedAt))
    }

    // MARK: - Publish

    private func tick() {
        guard let startedAt else { return }
        let now = Date().timeIntervalSince(startedAt)

        // Drain newly committed transcript lines (same cursor pattern as
        // MeetingNotesAccumulator). Lines carry no timestamps — stamping with
        // "now" lags speech by the commit delay, which is fine for the rate
        // signals these feed.
        if let transcriber {
            let lines = transcriber.transcriptLines
            if lines.count > consumedLineCount {
                for line in lines[consumedLineCount...] {
                    signals.ingestLine(
                        isMe: line.speaker == MeetingLiveTranscriber.meLabel,
                        text: line.text,
                        at: now
                    )
                }
                consumedLineCount = lines.count
            }
        }

        snapshot = signals.snapshot(at: now)

        // Nudges: fire from the fresh snapshot, auto-expire the display.
        // Pending ad-hoc items feed the reminder rule.
        let reminders = checklist
            .filter { $0.isPending && $0.source == .adhoc }
            .map { MeetingCoachNudger.PendingReminder(
                id: $0.id, text: $0.text, ageSeconds: now - $0.addedAtSeconds
            ) }
        // Set/profile/pasted items remind as one roll-up, not per item.
        let pendingKeyPoints = checklist
            .filter { $0.isPending && $0.source != .adhoc }
            .map(\.text)
        let scheduledFraction = scheduledEndElapsedSeconds.flatMap { end in
            end > 60 ? now / end : nil
        }
        if let nudge = nudger.evaluate(
            snapshot,
            reminders: reminders,
            pendingKeyPoints: pendingKeyPoints,
            scheduledFraction: scheduledFraction
        ) {
            activeNudge = nudge
            nudgeClearAt = Date().addingTimeInterval(Self.nudgeDisplaySeconds)
        } else if let clearAt = nudgeClearAt, Date() >= clearAt {
            activeNudge = nil
            nudgeClearAt = nil
        }
    }
}
