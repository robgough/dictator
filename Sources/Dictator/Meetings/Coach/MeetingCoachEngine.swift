import Foundation
import Observation

/// Owns the coach's live state for ONE recording. Constructed by
/// `MeetingSession` alongside the notes accumulator, fed from the recorders'
/// existing level callbacks and the live transcriber's committed lines, and
/// torn down with the recording.
///
/// Observation discipline (the `lastSystemLevel` lesson from
/// `MeetingSession`): level ingest happens ~100×/s and writes ONLY
/// `@ObservationIgnored` state — nothing observable mutates on the hot path.
/// A 1 Hz loop publishes one `snapshot` value, so the metrics strip
/// re-renders at most once a second.
@MainActor
@Observable
final class MeetingCoachEngine {
    /// The published signals — talk share, monologue timer, pace, etc.
    private(set) var snapshot = MeetingCoachSignals.Snapshot()

    /// The nudge currently on display, if any. Set when a rule fires,
    /// cleared automatically after `nudgeDisplaySeconds` — the island
    /// expands while this is non-nil and shrinks back when it clears.
    private(set) var activeNudge: CoachNudge?

    /// "Hide for this meeting" — set from the island's context menu. The
    /// island controller observes this; signals keep computing regardless
    /// (the post-meeting metrics don't stop because the strip is hidden).
    var chipHidden = false

    @ObservationIgnored private let signals = MeetingCoachSignals()
    @ObservationIgnored private let nudger = MeetingCoachNudger()
    @ObservationIgnored private var nudgeClearAt: Date?
    @ObservationIgnored private static let nudgeDisplaySeconds: TimeInterval = 8
    @ObservationIgnored private weak var transcriber: MeetingLiveTranscriber?
    @ObservationIgnored private var consumedLineCount = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?

    /// `transcriber` is nil when the live transcript is disabled — the coach
    /// still runs on levels alone (talk balance, monologues, interruptions);
    /// only the text-derived signals (pace, fillers, questions) stay empty.
    init(transcriber: MeetingLiveTranscriber?) {
        self.transcriber = transcriber
    }

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
        // One at a time — a fire while one is showing replaces it (rare:
        // every kind is on its own cooldown).
        if let nudge = nudger.evaluate(snapshot) {
            activeNudge = nudge
            nudgeClearAt = Date().addingTimeInterval(Self.nudgeDisplaySeconds)
        } else if let clearAt = nudgeClearAt, Date() >= clearAt {
            activeNudge = nil
            nudgeClearAt = nil
        }
    }
}
