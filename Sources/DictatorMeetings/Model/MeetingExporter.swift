import Foundation

/// Renders a `MeetingTranscript` (+ `MeetingMeta`) into plain text or
/// markdown for export. Pure-Foundation — lives in DictatorCore so the
/// iOS target can reuse the same renderer once meetings ship there.
enum MeetingExporter {
    /// Plain-text shape used by both the Copy-all button and the .txt
    /// export. One blank line between speaker turns; the timestamp goes
    /// in brackets next to the speaker name.
    static func plainText(transcript: MeetingTranscript, meta: MeetingMeta) -> String {
        let nameByID = Dictionary(uniqueKeysWithValues: meta.speakers.map { ($0.id, $0.displayName) })
        var lines: [String] = []
        lines.append(meta.title)
        lines.append(formatHeader(meta: meta))
        lines.append("")
        // Notes lead. New meetings carry markdown `notes`; older meetings only
        // have the structured `summary`. Markdown reads fine as plain text, so
        // we emit it verbatim for the .txt path too.
        if let notes = meta.notes, !notes.markdown.isEmpty {
            lines.append(notes.markdown)
            lines.append("")
        } else if let summary = meta.summary {
            lines.append(contentsOf: plainSummary(summary: summary))
            lines.append("")
        }
        for seg in transcript.segments {
            let name = nameByID[seg.speakerId] ?? seg.speakerId
            lines.append("[\(name) · \(formatTime(seg.start))]")
            lines.append(seg.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Markdown with speaker headings, blockquoted transcript text, and
    /// a summary section at the top if present. Designed to round-trip
    /// cleanly into notes apps (Obsidian, Bear, Notion). `screenshots`, when
    /// given, are interleaved as clickable links at their timeline position.
    static func markdown(transcript: MeetingTranscript, meta: MeetingMeta, screenshots: [ScreenshotRecord] = []) -> String {
        var lines: [String] = []
        lines.append("# \(meta.title)")
        lines.append("")
        lines.append("_\(formatHeader(meta: meta))_")
        lines.append("")
        // Notes lead. New meetings carry an LLM-authored markdown `notes`
        // body (emitted verbatim — it already uses `##` section headings);
        // older meetings fall back to rendering the structured `summary`.
        if let notes = meta.notes, !notes.markdown.isEmpty {
            lines.append(notes.markdown)
            lines.append("")
        } else if let summary = meta.summary {
            lines.append(contentsOf: markdownSummary(summary: summary))
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        lines.append(contentsOf: transcriptBody(transcript: transcript, meta: meta, screenshots: screenshots))
        return lines.joined(separator: "\n")
    }

    /// Transcript only, as Markdown — title + header + speaker turns, no notes
    /// section. Used when the user copies from the Transcript tab specifically,
    /// and to render the on-disk `transcript.md` (where `screenshots` carries
    /// the captured keyframes so their links land at the right moment).
    static func transcriptMarkdown(transcript: MeetingTranscript, meta: MeetingMeta, screenshots: [ScreenshotRecord] = []) -> String {
        var lines: [String] = ["# \(meta.title)", "", "_\(formatHeader(meta: meta))_", ""]
        lines.append(contentsOf: transcriptBody(transcript: transcript, meta: meta, screenshots: screenshots))
        return lines.joined(separator: "\n")
    }

    /// The speaker-turn body, with screenshot links interleaved at their
    /// capture time (each flushed just before the first turn that starts at or
    /// after it; any trailing ones land after the last turn).
    private static func transcriptBody(transcript: MeetingTranscript, meta: MeetingMeta, screenshots: [ScreenshotRecord]) -> [String] {
        let nameByID = Dictionary(uniqueKeysWithValues: meta.speakers.map { ($0.id, $0.displayName) })
        let shots = screenshots.sorted { $0.offsetSeconds < $1.offsetSeconds }
        var si = 0
        var lines: [String] = []
        func flushShots(upTo time: Double) {
            while si < shots.count, shots[si].offsetSeconds <= time {
                lines.append(screenshotLink(shots[si]))
                lines.append("")
                si += 1
            }
        }
        for seg in transcript.segments {
            flushShots(upTo: seg.start)
            let name = nameByID[seg.speakerId] ?? seg.speakerId
            lines.append("**\(name)** · `\(formatTime(seg.start))`")
            lines.append("")
            lines.append(seg.text)
            lines.append("")
        }
        flushShots(upTo: .greatestFiniteMagnitude)
        return lines
    }

    /// A clickable markdown link to one captured frame, relative to the meeting
    /// folder (`screenshots/<file>`). A link rather than an `![embed]` because
    /// HEIC doesn't render inline in most markdown viewers, but the link opens
    /// it in any of them.
    private static func screenshotLink(_ shot: ScreenshotRecord) -> String {
        "🖼 [Shared screen · \(formatTime(shot.offsetSeconds))](\(MeetingStorage.screenshotsFolderName)/\(shot.filename))"
    }

    // MARK: - Helpers

    private static func plainSummary(summary: MeetingSummaryResult) -> [String] {
        var lines: [String] = ["SUMMARY"]
        if !summary.narrative.isEmpty {
            lines.append(summary.narrative)
            lines.append("")
        }
        if !summary.decisions.isEmpty {
            lines.append("Decisions:")
            for d in summary.decisions { lines.append("  - \(d)") }
            lines.append("")
        }
        if !summary.actionItems.isEmpty {
            lines.append("Action items:")
            for item in summary.actionItems {
                if let owner = item.owner, !owner.isEmpty {
                    lines.append("  - \(owner): \(item.text)")
                } else {
                    lines.append("  - \(item.text)")
                }
            }
        }
        return lines
    }

    private static func markdownSummary(summary: MeetingSummaryResult) -> [String] {
        var lines: [String] = ["## Summary"]
        if !summary.narrative.isEmpty {
            lines.append("")
            lines.append(summary.narrative)
        }
        if !summary.decisions.isEmpty {
            lines.append("")
            lines.append("### Decisions")
            for d in summary.decisions { lines.append("- \(d)") }
        }
        if !summary.actionItems.isEmpty {
            lines.append("")
            lines.append("### Action items")
            for item in summary.actionItems {
                if let owner = item.owner, !owner.isEmpty {
                    lines.append("- **\(owner)**: \(item.text)")
                } else {
                    lines.append("- \(item.text)")
                }
            }
        }
        return lines
    }

    private static func formatHeader(meta: MeetingMeta) -> String {
        let date = headerDateFormatter.string(from: meta.createdAt)
        if meta.durationSeconds > 0 {
            return "\(date) · \(formatTime(meta.durationSeconds))"
        }
        return date
    }

    private static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
