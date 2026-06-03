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

    @ObservationIgnored private weak var transcriber: MeetingLiveTranscriber?
    @ObservationIgnored private let settings: DictatorSettings
    @ObservationIgnored private var consumedLineCount = 0
    @ObservationIgnored private var groups: [Group] = []
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var highlightClearTask: Task<Void, Never>?
    @ObservationIgnored private var inflight = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var ticksSincePass = 0

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

    init(transcriber: MeetingLiveTranscriber, settings: DictatorSettings) {
        self.transcriber = transcriber
        self.settings = settings
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
    /// into the notes — so the quick notes are complete when the recording
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
        guard lines.count > consumedLineCount else { return }

        let newLines = Array(lines[consumedLineCount...])
        let newChars = newLines.reduce(0) { $0 + $1.text.count }
        ticksSincePass += 1

        let enoughText = newChars >= Self.minNewChars
        let waitedLongEnough = ticksSincePass >= Self.maxIdleTicks && newChars > 0
        guard enoughText || waitedLongEnough else { return }

        // Claim this batch up front so concurrent ticks don't double-process,
        // and so a pass failure doesn't replay the same window forever.
        consumedLineCount = lines.count
        ticksSincePass = 0
        await runPass(newLines: newLines)
    }

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
    - If the new snippet has nothing worth noting (small talk, filler, repetition), output NOTHING AT ALL — an empty reply is correct and expected.
    - No preamble, no commentary. Markdown headings and bullets only, or nothing.
    """
}
