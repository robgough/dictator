import SwiftUI
import AppKit

/// Renders a meeting-notes markdown document. The notes use a small markdown
/// subset, so rather than pull in a full CommonMark renderer we parse the
/// shapes the notes actually use — `##`/`###` headings, `-`/`*`/`1.` bullets,
/// `- [ ]` / `- [x]` task items, two levels of nesting, ``` code fences,
/// `---` rules — and style each, using `AttributedString(markdown:)` for
/// inline emphasis (`**bold**`, `*italic*`, `` `code` ``).
///
/// Action-item niceties: a `- **Owner** — task` bullet renders the owner as a
/// chip tinted to the matching speaker's colour, and task checkboxes are
/// interactive — toggling one rewrites that line and persists via `onCommit`.
///
/// The raw markdown is always the source of truth — `onCommit`, when supplied,
/// also adds an Edit toggle that swaps the rendered view for a monospaced
/// `TextEditor`. The live first-pass pane renders its own structured outline,
/// not this view.
struct MarkdownNotesView: View {
    let markdown: String
    var speakers: [MeetingMeta.Speaker]
    var onCommit: ((String) -> Void)?
    /// When supplied, a bullet that carries a `[mm:ss]` timestamp shows a
    /// clickable time pill that calls this with the seconds — the notes panel
    /// wires it to jump the Transcript tab + seek the audio, so a surprising
    /// note can be checked against what was actually said.
    var onSeek: ((Double) -> Void)?
    /// When supplied, shows an "Assistant" button next to Edit — opens the
    /// notes assistant to ask questions about or edit the notes.
    var onAssistant: (() -> Void)?

    @State private var isEditing = false
    @State private var draft = ""

    init(
        markdown: String,
        speakers: [MeetingMeta.Speaker] = [],
        onCommit: ((String) -> Void)? = nil,
        onSeek: ((Double) -> Void)? = nil,
        onAssistant: (() -> Void)? = nil
    ) {
        self.markdown = markdown
        self.speakers = speakers
        self.onCommit = onCommit
        self.onSeek = onSeek
        self.onAssistant = onAssistant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if onCommit != nil || onAssistant != nil {
                HStack(spacing: 8) {
                    Spacer()
                    if let onAssistant, !isEditing {
                        Button(action: onAssistant) {
                            Label("Assistant", systemImage: "wand.and.stars")
                        }
                        .controlSize(.small)
                        .help("Ask about or edit these notes with the assistant.")
                    }
                    if onCommit != nil {
                        if isEditing {
                            Button("Done") {
                                onCommit?(draft)
                                isEditing = false
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                draft = markdown
                                isEditing = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if isEditing {
                // No card chrome here — callers place this view inside a
                // `.notesSurface()`, so the editor sits directly on that.
                TextEditor(text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading:
            HStack(spacing: 6) {
                if let symbol = Self.sectionSymbol(block.text) {
                    Image(systemName: symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                inline(block.text)
                    .font(block.level <= 2 ? .headline : .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.top, block.level <= 2 ? 12 : 6)
        case .bullet:
            bulletRow(marker: block.indent > 0 ? "◦" : "•", text: block.text, indent: block.indent)
        case .task:
            taskRow(block)
        case .numbered:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(block.number ?? 1).")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                ownerAware(block.text, allowOwner: false)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .paragraph:
            inline(block.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .code:
            Text(block.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func bulletRow(marker: String, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).foregroundStyle(.secondary)
            ownerAware(text, allowOwner: false)
        }
        .padding(.leading, CGFloat(indent) * 18)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func taskRow(_ block: MarkdownBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                toggleTask(body: block.text, currentlyChecked: block.checked)
            } label: {
                Image(systemName: block.checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(block.checked ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(onCommit == nil)
            ownerAware(block.text, allowOwner: true)
                .opacity(block.checked ? 0.55 : 1)
        }
        .padding(.leading, CGFloat(block.indent) * 18)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Render a bullet/task body. Strips any `[mm:ss]` / `[Speaker · mm:ss]`
    /// timestamp annotations (the model often copies the transcript's prefix
    /// format) into a single jump pill, and — only for action items
    /// (`allowOwner`) — pulls a leading `**Owner**` into a speaker chip. A bold
    /// lead-in on a Discussion bullet is a topic, NOT an owner, so it stays
    /// bold text rather than becoming a chip.
    @ViewBuilder
    private func ownerAware(_ text: String, allowOwner: Bool) -> some View {
        let (stripped, seconds) = MarkdownBlock.extractTimestamps(text)
        let (owner, rest) = allowOwner ? MarkdownBlock.splitOwner(stripped) : (nil, stripped)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let owner {
                NotesOwnerChip(owner: owner, speakers: speakers)
                inline(rest).font(.callout)
            } else {
                inline(stripped).font(.callout)
            }
            if let seconds, let onSeek {
                Button {
                    onSeek(seconds)
                } label: {
                    Label(Self.timeLabel(seconds), systemImage: "clock")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Jump to this moment in the transcript and audio.")
            }
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Toggle a `- [ ]` / `- [x]` task: find the matching line, flip its box,
    /// and persist the rewritten document via `onCommit`.
    private func toggleTask(body: String, currentlyChecked: Bool) {
        guard let onCommit else { return }
        var lines = markdown.components(separatedBy: "\n")
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard let (checked, taskBody) = MarkdownBlock.parseTask(trimmed),
                  checked == currentlyChecked, taskBody == body else { continue }
            let leading = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))
            lines[i] = "\(leading)- [\(currentlyChecked ? " " : "x")] \(taskBody)"
            break
        }
        onCommit(lines.joined(separator: "\n"))
    }

    private func inline(_ s: String) -> Text { inlineMarkdownText(s) }

    /// Map a canonical section heading to an SF Symbol, so the four-section
    /// structure reads at a glance. Returns nil for non-canonical headings.
    private static func sectionSymbol(_ heading: String) -> String? {
        let h = heading.lowercased()
        if h.contains("summary") || h.contains("tl;dr") { return "text.alignleft" }
        if h.contains("action") || h.contains("next step") || h.contains("to-do") || h.contains("todo") { return "checklist" }
        if h.contains("decision") { return "checkmark.seal" }
        if h.contains("question") || h.contains("parking") { return "questionmark.circle" }
        if h.contains("discussion") || h.contains("key point") || h.contains("topics") || h.contains("notes") { return "bubble.left.and.bubble.right" }
        return nil
    }
}

/// One action-item owner rendered as a speaker-tinted chip (mirrors the chip
/// in the transcript header). Falls back to neutral when the owner doesn't
/// match a known speaker.
struct NotesOwnerChip: View {
    let owner: String
    let speakers: [MeetingMeta.Speaker]

    var body: some View {
        let matched = speakers.first { $0.displayName.compare(owner, options: .caseInsensitive) == .orderedSame }
        let tint = matched.flatMap { speakerColor($0.colorHex) }
        HStack(spacing: 4) {
            Circle()
                .fill(tint ?? Color.secondary)
                .frame(width: 6, height: 6)
            Text(owner)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill((tint ?? Color.secondary).opacity(matched == nil ? 0.15 : 0.18)))
        .foregroundStyle(tint ?? .secondary)
    }
}

/// Parse a "#RRGGBB" hex (as stored on `MeetingMeta.Speaker`).
func speakerColor(_ hex: String) -> Color? {
    var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("#") { trimmed.removeFirst() }
    guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
    return Color(
        red: Double((value >> 16) & 0xff) / 255,
        green: Double((value >> 8) & 0xff) / 255,
        blue: Double(value & 0xff) / 255
    )
}

/// Render inline markdown emphasis (`**bold**`, `*italic*`, `` `code` ``) to a
/// `Text`, falling back to the raw string when it doesn't parse. Shared by the
/// finished notes renderer and the live outline view so both read alike.
func inlineMarkdownText(_ s: String) -> Text {
    let opts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    if let attr = try? AttributedString(markdown: s, options: opts) {
        return Text(attr)
    }
    return Text(s)
}

/// Copy-to-pasteboard button with a momentary "Copied" check, matching the
/// confirmation pattern the menu-bar recent rows use. `label` nil renders an
/// icon-only button.
struct CopyButton: View {
    let text: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation { copied = false }
            }
        } label: {
            if let label {
                Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .controlSize(.small)
        .tint(copied ? .green : nil)
        .help("Copy")
    }
}

extension View {
    /// Shared "notes surface" chrome — a text-field-like card (system text
    /// background + hairline border) used by both the live-recording notes
    /// pane and the finished notes panel so the two read the same.
    func notesSurface() -> some View {
        background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

/// A parsed markdown block. Deliberately tiny — only the shapes the notes
/// prompt emits.
struct MarkdownBlock {
    enum Kind { case heading, bullet, task, numbered, paragraph, code, rule }
    let kind: Kind
    let text: String
    let level: Int       // heading level (1…), else 0
    let number: Int?     // ordered-list index, else nil
    let indent: Int      // bullet nesting depth (0 top-level, 1 sub, 2 sub-sub)
    let checked: Bool    // task state, for .task

    init(kind: Kind, text: String, level: Int = 0, number: Int? = nil, indent: Int = 0, checked: Bool = false) {
        self.kind = kind
        self.text = text
        self.level = level
        self.number = number
        self.indent = indent
        self.checked = checked
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var codeLines: [String]?

        for rawLine in markdown.components(separatedBy: .newlines) {
            let leading = rawLine.prefix(while: { $0 == " " || $0 == "\t" }).count
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Code fence: toggle; collect verbatim lines between fences. But
            // small models sometimes wrap whole NOTE sections (bullets,
            // headings) in a fence — rendering those as a monospace code block
            // is wrong, so if the fenced content is really markdown we parse it
            // as markdown instead.
            if line.hasPrefix("```") {
                if let collected = codeLines {
                    if looksLikeMarkdown(collected) {
                        blocks.append(contentsOf: parse(collected.joined(separator: "\n")))
                    } else {
                        blocks.append(MarkdownBlock(kind: .code, text: collected.joined(separator: "\n")))
                    }
                    codeLines = nil
                } else {
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }

            if line.isEmpty { continue }

            // Horizontal rule: a line of only - * _ (3+).
            if line.count >= 3, line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) {
                blocks.append(MarkdownBlock(kind: .rule, text: ""))
                continue
            }

            // Heading: leading #'s.
            if line.hasPrefix("#") {
                let hashes = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(MarkdownBlock(kind: .heading, text: text, level: hashes))
                continue
            }

            // Unordered bullet (incl. task checkboxes). Nesting depth from the
            // leading indent: 0 / 2 / 4 spaces → level 0 / 1 / 2.
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                // Strip all leading markers so a stray `- - text` doesn't render
                // a bullet glyph plus a leftover dash.
                var body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                while body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                    body = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                let indent = min(2, leading / 2)
                if let (checked, taskBody) = parseTaskBody(body) {
                    blocks.append(MarkdownBlock(kind: .task, text: taskBody, indent: indent, checked: checked))
                } else {
                    blocks.append(MarkdownBlock(kind: .bullet, text: body, indent: indent))
                }
                continue
            }

            // Ordered list: "<n>. text".
            if let (number, rest) = orderedListItem(line) {
                blocks.append(MarkdownBlock(kind: .numbered, text: rest, number: number))
                continue
            }

            blocks.append(MarkdownBlock(kind: .paragraph, text: line))
        }
        if let collected = codeLines {  // unterminated fence
            if looksLikeMarkdown(collected) {
                blocks.append(contentsOf: parse(collected.joined(separator: "\n")))
            } else {
                blocks.append(MarkdownBlock(kind: .code, text: collected.joined(separator: "\n")))
            }
        }
        return blocks
    }

    /// Heuristic: a fenced block whose non-empty lines are mostly headings or
    /// bullets is really markdown the model mistakenly wrapped in a fence, not
    /// code. Treat it as markdown so it renders properly instead of monospace.
    private static func looksLikeMarkdown(_ lines: [String]) -> Bool {
        let content = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !content.isEmpty else { return false }
        let markdowny = content.filter {
            $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("+ ") || $0.hasPrefix("#")
        }.count
        return Double(markdowny) >= Double(content.count) * 0.6
    }

    /// Parse a `[ ] body` / `[x] body` task marker out of a bullet body.
    static func parseTaskBody(_ body: String) -> (checked: Bool, body: String)? {
        if body.hasPrefix("[ ] ") { return (false, String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)) }
        if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { return (true, String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Parse a full trimmed line `- [ ] body` into (checked, body). Used to
    /// locate a task line for toggling.
    static func parseTask(_ trimmed: String) -> (checked: Bool, body: String)? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return parseTaskBody(String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Pull a leading `**Owner**` (optionally followed by — / – / - / :) off a
    /// bullet body. Returns (owner, rest) only when both are non-empty, so a
    /// fully-bold bullet like `**Decision**` stays plain text.
    static func splitOwner(_ text: String) -> (owner: String?, rest: String) {
        guard text.hasPrefix("**") else { return (nil, text) }
        let afterOpen = text.dropFirst(2)
        guard let close = afterOpen.range(of: "**") else { return (nil, text) }
        let owner = String(afterOpen[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        var rest = String(afterOpen[close.upperBound...])
        rest = String(rest.drop(while: { $0 == " " || $0 == "—" || $0 == "–" || $0 == "-" || $0 == ":" }))
            .trimmingCharacters(in: .whitespaces)
        guard !owner.isEmpty, !rest.isEmpty else { return (nil, text) }
        return (owner, rest)
    }

    /// Strip every `[mm:ss]` / `[h:mm:ss]` / `[Speaker · mm:ss]` timestamp
    /// annotation out of a bullet — wherever it sits (trailing, inline, or
    /// wrapped in `(...)` with a trailing colon, all of which small models
    /// produce by echoing the transcript's `[Speaker · mm:ss]` line prefixes).
    /// Returns the cleaned text plus the first time found (for the jump pill).
    static func extractTimestamps(_ text: String) -> (text: String, seconds: Double?) {
        let pattern = "\\(?\\[[^\\]]*?(\\d{1,3}:\\d{2}(?::\\d{2})?)[^\\]]*?\\]\\)?:?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (text, nil) }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (text, nil) }

        var seconds: Double?
        if let first = matches.first, first.numberOfRanges > 1 {
            seconds = parseTime(ns.substring(with: first.range(at: 1)))
        }
        var result = text
        for match in matches.reversed() {
            if let r = Range(match.range, in: result) {
                result.replaceSubrange(r, with: " ")
            }
        }
        result = result.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        while let f = result.first, f == ":" || f == "-" || f == "—" || f == "–" {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return (result.isEmpty ? text : result, seconds)
    }

    private static func parseTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count, (2...3).contains(nums.count) else { return nil }
        return nums.count == 3
            ? Double(nums[0] * 3600 + nums[1] * 60 + nums[2])
            : Double(nums[0] * 60 + nums[1])
    }

    /// Parse a leading "12. " ordered-list marker.
    private static func orderedListItem(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let after = line.dropFirst(digits.count)
        guard after.hasPrefix(". ") else { return nil }
        return (n, String(after.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
}
