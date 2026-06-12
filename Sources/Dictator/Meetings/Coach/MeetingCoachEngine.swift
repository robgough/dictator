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

    @ObservationIgnored private let signals = MeetingCoachSignals()
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
    }
}
