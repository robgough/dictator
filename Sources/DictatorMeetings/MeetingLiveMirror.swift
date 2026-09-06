import Foundation

/// Streams an in-progress meeting's live first-pass notes and rolling live
/// transcript to plain files in the meeting's synced folder (beside
/// `meta.json`), refreshed on a short debounce as either one changes. Two
/// reasons it exists:
///
///   1. **Near-real-time external read.** A separate tool — e.g. a meeting
///      coach offering live advice — can watch the meetings folder for a
///      `live.json` whose `status` is `recording`, and read `live-notes.md` /
///      `live-transcript.md` (or the structured forms inside `live.json`) as
///      the meeting unfolds, without reaching into Dictator's process.
///   2. **Crash safety.** The notes/transcript otherwise live only in memory
///      until the recording stops (`MeetingSession.stopRecording`). Mirroring
///      them every few seconds means a crash mid-recording leaves the work on
///      disk instead of losing it.
///
/// The files are kept after the meeting ends — `finish(status:)` writes a final
/// snapshot with a terminal `status` rather than deleting — so they stand as a
/// readable first-pass record and give a reader a clean "ended" signal. The
/// polished, diarized output still lands separately in `meta.json` /
/// `transcript.json`.
///
/// The writer is I/O-only; the note-building / transcription logic stays in
/// `MeetingNotesAccumulator` / `MeetingLiveTranscriber`. Those two call back
/// into `scheduleWrite()` whenever their published state changes; this class
/// reads their current state and serialises it. Writes go through
/// `MeetingStorage`, which owns the on-disk layout.
@MainActor
final class MeetingLiveMirror {
    /// On-disk contract version for `live.json`. Bump on any breaking change to
    /// the `Snapshot` shape so external readers can detect it.
    static let schemaVersion = 1

    /// How long after a change to coalesce before writing. The producers
    /// already update on a coarse cadence (notes ~every 10 s, transcript per
    /// settled utterance), so this only smooths bursts — it isn't the main
    /// throttle.
    private static let debounce = Duration.milliseconds(400)

    private let meetingID: UUID
    private let title: String
    private let startedAt: Date
    private weak var transcriber: MeetingLiveTranscriber?
    private weak var accumulator: MeetingNotesAccumulator?

    private var writeTask: Task<Void, Never>?
    private var stopped = false

    init(
        meetingID: UUID,
        title: String,
        startedAt: Date,
        transcriber: MeetingLiveTranscriber,
        accumulator: MeetingNotesAccumulator?
    ) {
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.transcriber = transcriber
        self.accumulator = accumulator
    }

    /// Note that the live notes or transcript changed; write after a short
    /// debounce. Cheap and idempotent — safe to call on every producer update.
    func scheduleWrite() {
        guard !stopped else { return }
        writeTask?.cancel()
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.writeNow(status: .recording)
        }
    }

    /// Finalise the mirror: write one last snapshot carrying a terminal
    /// `status` (`stopped` for a clean stop, `interrupted` for a crash/failure)
    /// and stop the debounce. The files are kept — `status` is what tells a
    /// reader the meeting ended (so it can switch to the polished
    /// `meta.json` / `transcript.json`), and `live.json`-without-`meta.json` is
    /// how recovery spots a recording a crash cut short.
    ///
    /// Must be called while the producers are still alive (before the session
    /// nils them), so the final snapshot reflects the complete transcript/notes.
    func finish(status: Status) {
        stopped = true
        writeTask?.cancel()
        writeTask = nil
        writeNow(status: status)
    }

    // MARK: - Writing

    /// Write the initial snapshot immediately (synchronously, no debounce) so
    /// the three files exist from the instant recording starts — an external
    /// reader sees the meeting from t=0, and the user can watch them fill in
    /// rather than waiting ~30 s for the first committed line or notes pass.
    func start() {
        guard !stopped else { return }
        writeNow(status: .recording)
    }

    /// Prose (notes + transcript) is written as the `.md` files; the JSON
    /// carries only the *structured* form — status, timestamps, the outline
    /// groups, and the transcript lines — so the prose isn't duplicated. A
    /// reader wanting the text reads the `.md`; one wanting structure reads the
    /// JSON. Markdown files are written first and the JSON last, so a reader
    /// that keys off `updatedAt` then reads the `.md` sees a consistent set.
    private func writeNow(status: Status) {
        let notesMarkdown = accumulator?.liveNotes ?? ""
        let lines = (transcriber?.transcriptLines ?? []).map {
            Snapshot.Transcript.Line(speaker: $0.speaker, text: $0.text)
        }
        let snapshot = makeSnapshot(status: status, lines: lines)
        do {
            try MeetingStorage.writeLiveMirror(
                notesMarkdown: notesMarkdown,
                transcriptMarkdown: Self.renderTranscriptMarkdown(lines),
                state: snapshot,
                for: meetingID
            )
        } catch {
            // Best-effort — a failed mirror write must never disturb the
            // recording. The in-memory state is unaffected and the next tick
            // retries.
            NSLog("[Dictator] Live mirror write failed: \(error)")
        }
    }

    private func makeSnapshot(status: Status, lines: [Snapshot.Transcript.Line]) -> Snapshot {
        let groups: [Snapshot.Notes.Group] = (accumulator?.outline ?? []).map { g in
            Snapshot.Notes.Group(
                id: g.id,
                heading: g.heading,
                bullets: g.bullets.map { .init(id: $0.id, text: $0.text, indent: $0.indent) }
            )
        }
        let notes = Snapshot.Notes(
            isThinking: accumulator?.isThinking ?? false,
            topicCount: accumulator?.topicCount ?? 0,
            pointCount: accumulator?.pointCount ?? 0,
            groups: groups
        )
        return Snapshot(
            schemaVersion: Self.schemaVersion,
            meetingId: meetingID.uuidString,
            title: title,
            status: status,
            startedAt: startedAt,
            updatedAt: Date(),
            notes: notes,
            transcript: Snapshot.Transcript(lines: lines)
        )
    }

    /// Render the structured transcript lines to readable markdown: consecutive
    /// lines from the same speaker fold into one paragraph, a speaker change
    /// starts a fresh `**Speaker:**` line — matching how the live pane reads.
    private static func renderTranscriptMarkdown(_ lines: [Snapshot.Transcript.Line]) -> String {
        var out = ""
        var last: String?
        for line in lines {
            if out.isEmpty {
                out = "**\(line.speaker):** \(line.text)"
            } else if line.speaker == last {
                out.append(" " + line.text)
            } else {
                out.append("\n\n**\(line.speaker):** \(line.text)")
            }
            last = line.speaker
        }
        return out
    }

    // MARK: - Snapshot (the `live.json` contract)

    enum Status: String, Encodable {
        /// Actively capturing.
        case recording
        /// Cleanly stopped — the polished notes/transcript are (or will be) in
        /// meta.json / transcript.json.
        case stopped
        /// A crash or failure cut the recording short. Set by recovery on the
        /// next launch (the crash itself can't update the file).
        case interrupted
    }

    /// Structured form written to `live.json`. Encoded by `MeetingStorage`'s
    /// ISO-8601 / pretty-printed JSON encoder.
    struct Snapshot: Encodable {
        let schemaVersion: Int
        let meetingId: String
        let title: String
        let status: Status
        let startedAt: Date
        let updatedAt: Date
        let notes: Notes
        let transcript: Transcript

        struct Notes: Encodable {
            let isThinking: Bool
            let topicCount: Int
            let pointCount: Int
            let groups: [Group]

            struct Group: Encodable {
                let id: String
                let heading: String
                let bullets: [Bullet]

                struct Bullet: Encodable {
                    let id: String
                    let text: String
                    let indent: Int
                }
            }
        }

        struct Transcript: Encodable {
            let lines: [Line]

            struct Line: Encodable {
                let speaker: String
                let text: String
            }
        }
    }
}
