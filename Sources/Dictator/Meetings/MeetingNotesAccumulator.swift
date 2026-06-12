import Foundation
import Observation

/// Builds a rough *first pass* of the meeting notes while the meeting is still
/// recording. Lives alongside `MeetingLiveTranscriber` for the duration of a
/// live recording and, on a coalesced cadence, feeds the newest slice of live
/// transcript to the LLM and folds any fresh points into a growing,
/// **grouped** markdown outline (`liveNotes`) — topic headings with bullets
/// and sub-items beneath them.
///
/// Design — structured, incremental, single-flight:
///   - We keep an ordered set of topic groups (`## Heading` + bullet lines).
///     Each pass sees only the new transcript since the last pass, plus the
///     list of existing headings so the model can slot new points under a
///     topic that's already open. The model returns only *new* headings/
///     bullets, which we merge into the running outline (matching headings
///     case-insensitively, deduping bullets). This keeps every call cheap and
///     avoids the truncation small local models show when asked to rewrite a
///     whole document each time.
///   - One LLM call at a time. A pass only starts when enough new transcript
///     has landed (or enough time has passed) and no call is already running.
///   - The full, polished four-section notes are produced once the meeting
///     stops (`MeetingSummaryService.generateNotes`), superseding this.
///
/// Gated by the caller on `meetingLiveNotesEnabled` + an LLM being configured;
/// the accumulator itself assumes an engine is available. The LLM runs on the
/// GPU while Parakeet runs the live transcript on the ANE, so the two don't
/// contend for the same unit — but it's still extra power, hence the toggle.
@MainActor
@Observable
final class MeetingNotesAccumulator {
    /// The growing first-pass notes as grouped markdown. Observable so the
    /// live pane re-renders as new content lands. Used for copy/persist.
    private(set) var liveNotes: String = ""

    /// Structured form of the same outline, with stable identity per group and
    /// bullet so the live view can animate individual bullets in rather than
    /// re-rendering (and visibly teleporting) the whole document each pass.
    private(set) var outline: [NoteGroup] = []

    /// Bullet ids added by the most recent pass — the live view washes these
    /// with a brief highlight so the reader sees *what* changed. Cleared a
    /// moment later.
    private(set) var freshBulletIDs: Set<String> = []

    /// When the outline last gained content — drives the "updated Ns ago" cue.
    private(set) var lastUpdateAt: Date?

    /// True while an LLM pass is in flight — drives a calm "updating" hint
    /// in the live pane.
    private(set) var isThinking: Bool = false

    /// Number of topic groups (named headings) and total bullet points so far —
    /// the live "3 topics · 8 points" stat that visibly climbs as the meeting
    /// runs.
    var topicCount: Int { outline.reduce(0) { $0 + ($1.heading.isEmpty ? 0 : 1) } }
    var pointCount: Int { outline.reduce(0) { $0 + $1.bullets.count } }

    /// One bullet in the structured outline. `id` is stable across passes
    /// (derived from the group + normalised text) so SwiftUI keeps unchanged
    /// rows in place and only animates genuinely new ones.
    struct NoteBullet: Identifiable, Equatable, Sendable {
        let id: String
        let text: String
        let indent: Int
    }

    /// One topic group in the structured outline.
    struct NoteGroup: Identifiable, Equatable, Sendable {
        let id: String
        let heading: String
        var bullets: [NoteBullet]
    }

    /// Fired on the main actor whenever `liveNotes` changes (a pass folded in
    /// new content or a correction landed), so an observer can mirror the notes
    /// to disk. I/O-free here by design — the callback owns any persistence.
    @ObservationIgnored var onNotesUpdated: (() -> Void)?

    @ObservationIgnored private weak var transcriber: MeetingLiveTranscriber?
    @ObservationIgnored private let settings: DictatorSettings
    /// The coach engine, when this meeting has a checklist to watch. The
    /// watcher rides this accumulator's cadence loop so there's only ever
    /// ONE live LLM consumer, strictly serialised with the notes passes.
    @ObservationIgnored private weak var coach: MeetingCoachEngine?
    /// False = checklist-only mode (live notes off but a checklist exists):
    /// the additive/correction passes are skipped, the loop machinery and
    /// the watcher still run.
    @ObservationIgnored private let notesEnabled: Bool
    @ObservationIgnored private var consumedLineCount = 0
    @ObservationIgnored private var groups: [Group] = []
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var highlightClearTask: Task<Void, Never>?
    @ObservationIgnored private var inflight = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var ticksSincePass = 0
    /// Ticks since the last correction pass, and how far through the transcript
    /// that pass had seen — the correction cadence is independent of the
    /// additive pass's `consumedLineCount`.
    @ObservationIgnored private var ticksSinceCorrection = 0
    @ObservationIgnored private var lastCorrectionLineCount = 0
    /// Checklist-watcher cursor + cadence (see runChecklistPass).
    @ObservationIgnored private var checklistLineCount = 0
    @ObservationIgnored private var ticksSinceChecklist = 0
    @ObservationIgnored private var totalTicks = 0

    /// One topic group in the running outline: a heading (empty for the
    /// general/un-grouped bucket) and its bullet lines (each already
    /// normalised to `- ` / `  - ` markdown, sub-items keeping their indent).
    private struct Group { var heading: String; var lines: [String] }

    /// How often the loop wakes to consider a pass.
    private static let tickSeconds: UInt64 = 10
    /// Run a pass once this many new transcript characters have accumulated…
    private static let minNewChars = 260
    /// …or after this many idle ticks with *any* new content, so a slow
    /// meeting still gets periodic notes instead of waiting for a big batch.
    /// Kept short so the first bullets appear within ~30–45 s — the live build
    /// should feel responsive, not batched.
    private static let maxIdleTicks = 3   // 10 s × 3 ≈ 30 s
    /// Cap on the existing-heading context we feed back for placement.
    private static let maxContextHeadings = 16

    // MARK: Correction cadence
    //
    // The correction pass is the "self-correct on the fly" path: rather than
    // only appending, it periodically asks the model whether the latest
    // conversation has *contradicted* an earlier point (a reversed decision, a
    // corrected number) and applies a small diff. It runs much less often than
    // the additive pass and emits a tiny output (drop/edit lines, usually
    // nothing), so it never enters the truncation regime a whole-document
    // rewrite would on a small local model.

    /// Run a correction pass at most once every this many ticks (≈ 60 s).
    private static let correctionEveryTicks = 6
    /// Don't bother correcting an outline smaller than this — too little to
    /// have gone stale, and the cost isn't worth it.
    private static let minBulletsForCorrection = 4
    /// Trailing transcript lines handed to the correction pass as "what just
    /// changed". The whole outline is shown as numbered context, but only
    /// recent speech can justify a correction.
    private static let maxRecentLinesForCorrection = 12
    /// Cap on how many bullets we number into the correction prompt (the most
    /// recent ones) — bounds the prompt and keeps the model's attention on
    /// plausibly-revisable content.
    private static let maxBulletsInCorrectionPrompt = 50
    /// Blast-radius cap: apply at most this many corrections per pass, so a
    /// confused model can't rewrite the whole outline in one go.
    private static let maxCorrectionsPerPass = 3
    /// Reject an edited bullet longer than this — a correction should be a
    /// terse replacement, not a paragraph.
    private nonisolated static let maxEditedBulletChars = 200

    init(
        transcriber: MeetingLiveTranscriber,
        settings: DictatorSettings,
        coach: MeetingCoachEngine? = nil,
        notesEnabled: Bool = true
    ) {
        self.transcriber = transcriber
        self.settings = settings
        self.coach = coach
        self.notesEnabled = notesEnabled
    }

    /// Warm the engine and start the cadence loop. Safe to call once.
    func start() {
        guard loopTask == nil else { return }
        // Warm the LLM so the first pass isn't a cold stall mid-meeting.
        Task { [settings] in try? await settings.activeLLMEngine()?.ensureReady() }
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
                guard let self, !self.stopped else { break }
                await self.tick()
            }
        }
    }

    /// Stop the loop and cancel any in-flight pass. Returns the first-pass
    /// notes accumulated so far (may be empty) so the session can persist them.
    func stop() -> String {
        stopped = true
        loopTask?.cancel()
        loopTask = nil
        highlightClearTask?.cancel()
        highlightClearTask = nil
        freshBulletIDs = []
        return liveNotes
    }

    /// Stop the loop, then run one last pass over any transcript not yet folded
    /// into the notes — so the live notes are complete when the recording
    /// stops (paired with the transcriber's `finishPending()`). Returns the
    /// finished notes. Await this before `stop()` is otherwise needed.
    func finish() async -> String {
        loopTask?.cancel()
        await loopTask?.value          // let any in-flight cadence pass unwind
        loopTask = nil
        highlightClearTask?.cancel()
        highlightClearTask = nil
        freshBulletIDs = []
        if let transcriber {
            let lines = transcriber.transcriptLines
            if lines.count > consumedLineCount {
                let newLines = Array(lines[consumedLineCount...])
                consumedLineCount = lines.count
                await runPass(newLines: newLines)
            }
        }
        stopped = true
        return liveNotes
    }

    /// Rebuild the structured `outline` from the grouped lines, assigning each
    /// group + bullet a stable id (group key + normalised bullet text) so the
    /// view diffs cleanly across passes.
    private func rebuildOutline() {
        outline = groups.map { g in
            let key = Self.normalise(g.heading)
            let bullets = g.lines.map { line -> NoteBullet in
                let indent = line.hasPrefix("  ") ? 1 : 0
                var text = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
                    text = String(text.dropFirst(marker.count))
                    break
                }
                return NoteBullet(
                    id: "\(key)#\(Self.normaliseBullet(line))",
                    text: text,
                    indent: indent
                )
            }
            return NoteGroup(id: key.isEmpty ? "__general" : key, heading: g.heading, bullets: bullets)
        }
    }

    /// Clear the freshly-added highlight a beat after it lands, so the wash
    /// fades rather than sticking.
    private func scheduleHighlightClear() {
        highlightClearTask?.cancel()
        highlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, !self.stopped else { return }
            self.freshBulletIDs = []
        }
    }

    // MARK: - Cadence

    private func tick() async {
        guard !stopped, !inflight else { return }
        guard let transcriber else { return }
        let lines = transcriber.transcriptLines
        ticksSinceCorrection += 1
        totalTicks += 1

        // ── Additive pass: fold genuinely new transcript into the outline. ──
        if notesEnabled, lines.count > consumedLineCount {
            let newLines = Array(lines[consumedLineCount...])
            let newChars = newLines.reduce(0) { $0 + $1.text.count }
            ticksSincePass += 1
            let enoughText = newChars >= Self.minNewChars
            let waitedLongEnough = ticksSincePass >= Self.maxIdleTicks && newChars > 0
            if enoughText || waitedLongEnough {
                // Claim this batch up front so a pass failure doesn't replay
                // the same window forever.
                consumedLineCount = lines.count
                ticksSincePass = 0
                await runPass(newLines: newLines)
            }
        }

        // ── Checklist watcher: narrow classification over new lines —     ──
        // which unticked key points were just addressed? Runs after the
        // additive pass on the same single-flight loop (notes win
        // contention by construction). Adaptive cadence: every tick for the
        // first 5 minutes (intros and agenda-setting tick most items),
        // every 3 ticks after.
        if !stopped, coach?.hasChecklist == true {
            let fastPhase = totalTicks * Int(Self.tickSeconds) < 300
            ticksSinceChecklist += 1
            if (fastPhase || ticksSinceChecklist >= 3),
               lines.count > checklistLineCount {
                await runChecklistPass(lines: lines)
            }
        }

        // ── Correction pass: on a slower cadence, revise points the later ──
        // conversation has contradicted. Runs independently of the additive
        // cursor (it may fire on the same tick that just appended) so a fast
        // meeting doesn't starve it.
        guard !stopped, notesEnabled, settings.meetingLiveNotesSelfCorrectEnabled else { return }
        guard ticksSinceCorrection >= Self.correctionEveryTicks else { return }
        guard pointCount >= Self.minBulletsForCorrection else { return }
        guard lines.count > lastCorrectionLineCount else { return }
        let recent = Array(Array(lines[lastCorrectionLineCount...]).suffix(Self.maxRecentLinesForCorrection))
        lastCorrectionLineCount = lines.count
        ticksSinceCorrection = 0
        await runCorrectionPass(recentLines: recent)
    }

    // MARK: - Checklist watcher

    /// Match new transcript lines against the coach's unticked checklist.
    /// Tight contract mirroring the correction pass: numbered items in,
    /// `DONE n` lines (or nothing) out, anything else ignored. Items only
    /// ever tick — the watcher can't untick. A cheap keyword prefilter skips
    /// the LLM call entirely when no new line shares a content word with any
    /// unticked item, which is most of a long meeting.
    private func runChecklistPass(lines: [MeetingLiveTranscriber.LiveLine]) async {
        guard let coach, let engine = settings.activeLLMEngine() else { return }
        let windowStart = checklistLineCount
        let newLines = Array(lines[windowStart...])
        // Claim the window up front (same as the additive pass) so a failed
        // call doesn't replay forever. Items added mid-window become
        // watchable from the NEXT window — never against earlier speech.
        checklistLineCount = lines.count
        ticksSinceChecklist = 0

        let items = coach.watchableItems(beforeLine: windowStart)
        guard !items.isEmpty else { return }

        // Prefilter: any ≥4-char word from an item appearing in a new line?
        let lineBlob = newLines.map(\.text).joined(separator: " ").lowercased()
        let lineWords = Set(lineBlob.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 4 })
        let plausible = items.contains { item in
            item.text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .contains { $0.count >= 4 && lineWords.contains($0) }
        }
        guard plausible else { return }

        inflight = true
        isThinking = true
        defer { inflight = false; isThinking = false }

        let numbered = items.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n")
        let snippet = newLines
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let selection = """
        KEY POINTS NOT YET COVERED:
        \(numbered)

        NEW TRANSCRIPT:
        \(snippet)
        """

        do {
            let result = try await engine.assist(
                selection: selection,
                instruction: "Which numbered key points did the NEW TRANSCRIPT clearly address? Output only DONE lines, or nothing.",
                systemPrompt: Self.checklistPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
            guard !stopped else { return }
            let doneNumbers = Self.parseDone(LLMTextUtilities.clean(result.text))
            let ids = doneNumbers.compactMap { n -> String? in
                guard n >= 1, n <= items.count else { return nil }
                return items[n - 1].id
            }
            guard !ids.isEmpty else { return }
            coach.markDone(ids: ids)
        } catch {
            NSLog("[Dictator] Checklist watcher pass failed: \(error)")
        }
    }

    /// Parse `DONE n` lines; anything else is ignored so stray prose can't
    /// tick items.
    private nonisolated static func parseDone(_ raw: String) -> [Int] {
        raw.components(separatedBy: .newlines).compactMap { rawLine in
            let line = stripLeadingBulletMarkers(rawLine.trimmingCharacters(in: .whitespaces))
                .trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("done") else { return nil }
            return firstInt(in: line)
        }
    }

    private static let checklistPrompt = """
    You are watching a meeting IN PROGRESS against a short list of key points the user wants to make sure get covered.

    You receive the NOT-YET-COVERED points as a numbered list, and a NEW snippet of transcript labelled `Me:` / `Them:`.

    Output ONLY lines of the form `DONE n` — one per numbered point that the NEW transcript clearly and substantively addressed. A passing mention is not enough; the point must have actually been discussed or done.

    If none were addressed, output NOTHING AT ALL — an empty reply is correct and expected, and is the common case.

    No preamble, no commentary. Only DONE lines, or nothing.
    """

    private func runPass(newLines: [MeetingLiveTranscriber.LiveLine]) async {
        guard let engine = settings.activeLLMEngine() else { return }
        inflight = true
        isThinking = true
        defer { inflight = false; isThinking = false }

        let snippet = newLines
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let headings = groups.map(\.heading).filter { !$0.isEmpty }.suffix(Self.maxContextHeadings)
        let headingList = headings.isEmpty ? "(none yet)" : headings.map { "- \($0)" }.joined(separator: "\n")
        let selection = """
        EXISTING HEADINGS:
        \(headingList)

        NEW TRANSCRIPT:
        \(snippet)
        """

        do {
            let result = try await engine.assist(
                selection: selection,
                instruction: "Fold the new transcript into the notes: reuse an existing heading when the point belongs to it, otherwise add a new one. Output markdown headings + bullets for the NEW points only, or nothing.",
                systemPrompt: Self.livePrompt,
                priorTurns: [],
                summary: nil,
                // The pass runs inside `loopTask`, which `stop()` cancels —
                // so task cancellation is the stop signal (and it's safe to
                // read from this @Sendable closure, unlike main-actor state).
                cancellation: { Task.isCancelled }
            )
            guard !stopped else { return }
            let incoming = Self.parseGroups(LLMTextUtilities.clean(result.text))
            guard !incoming.isEmpty else { return }
            let previousIDs = Set(outline.flatMap { $0.bullets.map(\.id) })
            merge(incoming)
            rebuildOutline()
            let newIDs = Set(outline.flatMap { $0.bullets.map(\.id) })
            let added = newIDs.subtracting(previousIDs)
            liveNotes = render()
            onNotesUpdated?()
            if !added.isEmpty {
                freshBulletIDs = added
                lastUpdateAt = Date()
                scheduleHighlightClear()
            }
        } catch {
            // Best-effort — a failed live pass just means those lines don't
            // produce notes. The final pass still sees the whole transcript.
            NSLog("[Dictator] Live notes pass failed: \(error)")
        }
    }

    // MARK: - Correction pass

    /// One correction the model asked for against the numbered outline.
    private enum Correction {
        case drop(Int)
        case edit(Int, String)
    }

    /// Show the model the current outline (numbered) plus the most recent
    /// transcript, and apply any drop/edit corrections it returns. Output is a
    /// tiny diff, so this stays clear of the rewrite-truncation that asking a
    /// small local model to re-emit the whole document would hit.
    private func runCorrectionPass(recentLines: [MeetingLiveTranscriber.LiveLine]) async {
        guard let engine = settings.activeLLMEngine() else { return }
        guard !recentLines.isEmpty else { return }
        let (numbered, refs) = numberedOutlineForCorrection()
        guard refs.count >= Self.minBulletsForCorrection else { return }

        inflight = true
        isThinking = true
        defer { inflight = false; isThinking = false }

        let snippet = recentLines
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        let selection = """
        CURRENT NOTES (numbered):
        \(numbered)

        RECENT TRANSCRIPT:
        \(snippet)
        """

        do {
            let result = try await engine.assist(
                selection: selection,
                instruction: "Review the numbered notes against the recent transcript. Output ONLY the DROP/EDIT corrections the recent transcript clearly justifies, or nothing at all.",
                systemPrompt: Self.correctionPrompt,
                priorTurns: [],
                summary: nil,
                cancellation: { Task.isCancelled }
            )
            guard !stopped else { return }
            let corrections = Self.parseCorrections(LLMTextUtilities.clean(result.text))
            guard !corrections.isEmpty else { return }
            let previousIDs = Set(outline.flatMap { $0.bullets.map(\.id) })
            guard applyCorrections(corrections, refs: refs) else { return }
            rebuildOutline()
            liveNotes = render()
            onNotesUpdated?()
            // Edited bullets get a new id (their text changed); wash those in.
            // Pure drops just vanish — nothing to highlight.
            let newIDs = Set(outline.flatMap { $0.bullets.map(\.id) })
            freshBulletIDs = newIDs.subtracting(previousIDs)
            lastUpdateAt = Date()
            scheduleHighlightClear()
        } catch {
            NSLog("[Dictator] Live notes correction pass failed: \(error)")
        }
    }

    /// Flatten the outline's bullets into a numbered list (most recent
    /// `maxBulletsInCorrectionPrompt`), grouped under their headings, and return
    /// it alongside a 0-based `refs` array mapping displayed number → the
    /// `(group, line)` it points at. The numbering and the refs are built from
    /// the same snapshot, so applying a correction by number is exact.
    private func numberedOutlineForCorrection() -> (text: String, refs: [(g: Int, l: Int)]) {
        var flat: [(g: Int, l: Int, indent: Bool, body: String)] = []
        for (gi, group) in groups.enumerated() {
            for (li, line) in group.lines.enumerated() {
                let indent = line.hasPrefix("  ")
                var body = line.trimmingCharacters(in: .whitespaces)
                for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) {
                    body = String(body.dropFirst(marker.count)); break
                }
                flat.append((gi, li, indent, body))
            }
        }
        let kept = Array(flat.suffix(Self.maxBulletsInCorrectionPrompt))

        var rendered: [String] = []
        var refs: [(g: Int, l: Int)] = []
        var lastHeadingShown: String?
        for (idx, entry) in kept.enumerated() {
            let heading = groups[entry.g].heading
            if heading != lastHeadingShown {
                if !heading.isEmpty { rendered.append("## \(heading)") }
                lastHeadingShown = heading
            }
            let pad = entry.indent ? "  " : ""
            rendered.append("\(pad)\(idx + 1). \(entry.body)")
            refs.append((entry.g, entry.l))
        }
        return (rendered.joined(separator: "\n"), refs)
    }

    /// Apply parsed corrections to `groups` (capped at `maxCorrectionsPerPass`).
    /// Drops and edits are gathered keyed by `(group, line)` first, then applied
    /// in a single rebuild so list indices never shift mid-apply. Returns true
    /// if anything actually changed.
    private func applyCorrections(_ corrections: [Correction], refs: [(g: Int, l: Int)]) -> Bool {
        func key(_ g: Int, _ l: Int) -> String { "\(g):\(l)" }
        var drops = Set<String>()
        var edits: [String: String] = [:]
        var applied = 0

        for correction in corrections {
            if applied >= Self.maxCorrectionsPerPass { break }
            switch correction {
            case .drop(let n):
                guard n >= 1, n <= refs.count else { continue }
                let ref = refs[n - 1]
                let k = key(ref.g, ref.l)
                guard !drops.contains(k) else { continue }
                drops.insert(k)
                edits[k] = nil
                applied += 1
            case .edit(let n, let text):
                guard n >= 1, n <= refs.count else { continue }
                guard let body = Self.sanitiseCorrectionText(text) else { continue }
                let ref = refs[n - 1]
                let k = key(ref.g, ref.l)
                guard !drops.contains(k) else { continue }
                edits[k] = body
                applied += 1
            }
        }
        guard applied > 0 else { return false }

        var changed = false
        for gi in groups.indices {
            var newLines: [String] = []
            newLines.reserveCapacity(groups[gi].lines.count)
            for (li, line) in groups[gi].lines.enumerated() {
                let k = key(gi, li)
                if drops.contains(k) { changed = true; continue }
                if let body = edits[k] {
                    let rebuilt = (line.hasPrefix("  ") ? "  - " : "- ") + body
                    if rebuilt != line { changed = true }
                    newLines.append(rebuilt)
                } else {
                    newLines.append(line)
                }
            }
            groups[gi].lines = newLines
        }
        let groupsBefore = groups.count
        groups.removeAll { $0.lines.isEmpty }
        if groups.count != groupsBefore { changed = true }
        return changed
    }

    /// Tidy a model-proposed replacement bullet: strip any leading markers it
    /// echoed, trim, and reject if empty or implausibly long.
    private nonisolated static func sanitiseCorrectionText(_ raw: String) -> String? {
        let body = stripLeadingBulletMarkers(raw.trimmingCharacters(in: .whitespaces))
            .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, body.count <= maxEditedBulletChars else { return nil }
        return body
    }

    /// Parse the model's reply into `DROP n` / `EDIT n: text` corrections.
    /// Anything that isn't one of those two shapes is ignored, so stray prose
    /// can't leak in.
    private nonisolated static func parseCorrections(_ raw: String) -> [Correction] {
        var out: [Correction] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = stripLeadingBulletMarkers(rawLine.trimmingCharacters(in: .whitespaces))
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("drop") {
                if let n = firstInt(in: line) { out.append(.drop(n)) }
            } else if lower.hasPrefix("edit") {
                // `EDIT n: replacement text` — the colon is the reliable split.
                guard let n = firstInt(in: line), let colon = line.firstIndex(of: ":") else { continue }
                let text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { out.append(.edit(n, String(text))) }
            }
        }
        return out
    }

    /// First run of digits in `s` as an Int, or nil.
    private nonisolated static func firstInt(in s: String) -> Int? {
        var digits = ""
        var started = false
        for ch in s {
            if ch.isNumber { digits.append(ch); started = true }
            else if started { break }
        }
        return Int(digits)
    }

    private static let correctionPrompt = """
    You are reviewing the running notes of a meeting that is STILL IN PROGRESS, to fix points that LATER conversation has corrected, reversed, or made obsolete.

    You receive the current notes as a NUMBERED list of bullets (grouped under their `##` headings), and a RECENT TRANSCRIPT snippet labelled `Me:` / `Them:`.

    Output ONLY corrections the recent transcript clearly justifies, one per line, in exactly these forms:
    - `DROP n` — remove bullet n (it was withdrawn or reversed, or is now plainly wrong).
    - `EDIT n: <corrected text>` — replace bullet n's text (a changed decision, a corrected fact or number).

    Rules:
    - Correct ONLY what the RECENT TRANSCRIPT actually changes. If an earlier note is still accurate, leave it alone.
    - Do NOT rewrite for style, do NOT add new points, do NOT renumber, do NOT restate unchanged bullets. This is a correction pass, not a rewrite.
    - Keep an edited bullet short, in the same terse voice as the others. Do not attribute it to a named person.
    - If nothing needs correcting, output NOTHING AT ALL — an empty reply is correct and expected, and is the common case.

    Example — if bullet 4 reads "Decided to launch in Q3" and the recent transcript is "Them: actually, let's push the launch to Q4", output exactly:
    EDIT 4: Decided to launch in Q4

    No preamble, no commentary. Only DROP/EDIT lines, or nothing.
    """

    // MARK: - Merge

    /// Fold incoming groups into the running outline. Points under a heading
    /// that already exists (case-insensitively, allowing partial overlap)
    /// append to it; genuinely new headings become new groups. Bullets are
    /// deduped against what the group already holds.
    private func merge(_ incoming: [Group]) {
        for ing in incoming {
            if let idx = indexOfGroup(matching: ing.heading) {
                for line in ing.lines where !isDuplicate(line, in: groups[idx]) {
                    groups[idx].lines.append(line)
                }
            } else {
                var fresh = Group(heading: ing.heading, lines: [])
                for line in ing.lines where !isDuplicate(line, in: fresh) {
                    fresh.lines.append(line)
                }
                guard !fresh.lines.isEmpty else { continue }
                groups.append(fresh)
            }
        }
    }

    private func indexOfGroup(matching heading: String) -> Int? {
        let key = Self.normalise(heading)
        return groups.firstIndex { g in
            let k = Self.normalise(g.heading)
            if key.isEmpty || k.isEmpty { return k == key }
            return k == key || k.contains(key) || key.contains(k)
        }
    }

    private func isDuplicate(_ line: String, in group: Group) -> Bool {
        let key = Self.normaliseBullet(line)
        guard !key.isEmpty else { return true }
        return group.lines.contains { Self.normaliseBullet($0) == key }
    }

    private func render() -> String {
        var out: [String] = []
        for g in groups {
            if !g.heading.isEmpty {
                if !out.isEmpty { out.append("") }
                out.append("## \(g.heading)")
            }
            out.append(contentsOf: g.lines)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    /// Parse the model's markdown reply into topic groups. Recognises `##`
    /// headings and `-`/`*`/`+` bullets (a 2-space / tab indent marks a
    /// sub-item); anything else is ignored so stray prose can't leak in.
    private nonisolated static func parseGroups(_ raw: String) -> [Group] {
        var result: [Group] = []
        var current: Group?

        func flush() {
            if let c = current, !c.lines.isEmpty || !c.heading.isEmpty { result.append(c) }
            current = nil
        }

        for rawLine in raw.components(separatedBy: .newlines) {
            let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            let t = rawLine.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }

            if t.hasPrefix("#") {
                flush()
                let heading = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                current = Group(heading: heading, lines: [])
                continue
            }

            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                // Strip *all* leading bullet markers — the model sometimes emits
                // `- - text`, which otherwise renders a bullet glyph AND a stray
                // "- " in the body.
                let body = stripLeadingBulletMarkers(t)
                guard !body.isEmpty else { continue }
                let line = (leading >= 2 ? "  - " : "- ") + body
                if current == nil { current = Group(heading: "", lines: []) }
                current?.lines.append(line)
            }
        }
        flush()

        // Drop a leading empty-heading group with no lines (artifact of a reply
        // that opened with a heading we flushed).
        return result.filter { !($0.heading.isEmpty && $0.lines.isEmpty) }
    }

    /// Strip every leading bullet marker (`- ` / `* ` / `+ `) off a line, so a
    /// model that emits `- - text` doesn't leave a stray dash in the body.
    private nonisolated static func stripLeadingBulletMarkers(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Collapse a heading to a comparison key (letters + digits only).
    nonisolated static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Collapse a bullet line (stripping marker + indent) to a comparison key.
    nonisolated static func normaliseBullet(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where t.hasPrefix(marker) {
            t = String(t.dropFirst(marker.count))
            break
        }
        return normalise(t)
    }

    private static let livePrompt = """
    You are taking live, organised notes during a meeting that is still in progress. You receive the topic headings captured so far and a NEW snippet of transcript, labelled by speaker (`Me:` is the person recording, `Them:` is the other side).

    Group the notes under short topic headings (a few words each). Output markdown:
    - `## Heading` for each topic the NEW snippet adds to.
    - Under each heading, `- ` bullets for the points. Use a two-space indent `  - ` for a sub-point that elaborates the bullet above it.

    Rules:
    - REUSE an existing heading verbatim when the new content belongs to a topic already open — only create a new heading for a genuinely new topic.
    - Output ONLY headings and bullets for points that are NEW in this snippet. Do not repeat points already captured.
    - Keep bullets short and concrete. At most about 6 bullets total per snippet.
    - ATTRIBUTION: you only know two labels — `Me` (the recorder) and `Them` (everyone else on the call). When more than one person is on the other side they are ALL `Them`, so you CANNOT tell which of them said any given thing. Never guess a person's name and never write "<Name> said/wants/will…". Write each point topically (what was said), not as a quote credited to a named individual. A point being ABOUT a person ("they think Jacob should…") is NOT the same as that person saying it — do not flip it into "Jacob said…". Only "Me"/"you" may be used, and only for a line that is clearly from `Me:`.
    - If the new snippet has nothing worth noting (small talk, filler, repetition), output NOTHING AT ALL — an empty reply is correct and expected.
    - No preamble, no commentary. Markdown headings and bullets only, or nothing.
    """
}
