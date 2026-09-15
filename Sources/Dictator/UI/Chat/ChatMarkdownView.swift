import AppKit
import SwiftUI

/// Renders an assistant reply: prose as markdown, code as code.
///
/// Replaces a single `Text(AttributedString(markdown:))`, which could only do
/// inline markdown — so a fenced block arrived with its backticks intact and
/// its newlines folded away, turning a script the model wrote line by line into
/// one unreadable line.
struct ChatMarkdownView: View {
    let text: String
    /// True while the reply is still arriving.
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(ChatMarkdown.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let prose):
                    Text(inline(prose))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code, isStreaming: isStreaming)
                }
            }
        }
    }

    /// Inline markdown only — bold, links, `code` spans. Block structure is
    /// handled above, so this never sees a fence.
    ///
    /// `.inlineOnlyPreservingWhitespace` keeps the line breaks the model put in
    /// a list or a short paragraph, which full markdown parsing would collapse.
    private func inline(_ prose: String) -> AttributedString {
        (try? AttributedString(
            markdown: prose,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(prose)
    }
}

/// One fenced code block *inside a reply*: language label, copy button, and a
/// frame of its own.
///
/// All three exist because a code block in the middle of prose has nothing
/// else around it to say what it is. Somewhere that already provides them —
/// `ChatFileCard`, which names the file, draws a border and has its own copy
/// button — wants `ChatCodeView` instead, or you get a card inside a card with
/// two copy buttons.
private struct CodeBlockView: View {
    let language: String?
    let code: String
    var isStreaming: Bool

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.map(displayName) ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // Nothing to copy until it's finished arriving.
                if !isStreaming {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5))

            ChatCodeView(language: language, code: code)
        }
        .background(.quaternary.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func displayName(_ language: String) -> String {
        switch language {
        case "js", "javascript": return "JavaScript"
        case "ts", "typescript": return "TypeScript"
        case "rb", "ruby": return "Ruby"
        case "py", "python": return "Python"
        case "sh", "bash", "zsh", "shell": return "Shell"
        case "json": return "JSON"
        case "swift": return "Swift"
        case "html": return "HTML"
        case "css": return "CSS"
        case "sql": return "SQL"
        case "yaml", "yml": return "YAML"
        case "md", "markdown": return "Markdown"
        default: return language.capitalized
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// Syntax-highlighted source, and nothing else — no label, no copy button, no
/// frame.
///
/// Long lines scroll sideways rather than wrapping: wrapping is the wrong
/// default for code, because a wrapped line reads as two statements.
struct ChatCodeView: View {
    let language: String?
    let code: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var highlighted: AttributedString {
        var output = AttributedString(code)
        output.foregroundColor = .primary
        for token in CodeHighlighter.tokens(in: code, language: language) {
            guard let lower = AttributedString.Index(token.range.lowerBound, within: output),
                  let upper = AttributedString.Index(token.range.upperBound, within: output)
            else { continue }
            output[lower..<upper].foregroundColor = colour(for: token.kind)
        }
        return output
    }

    /// Picked to stay legible in both appearances — SwiftUI's semantic colours
    /// adapt, hand-mixed hex values don't.
    private func colour(for kind: CodeHighlighter.Kind) -> Color {
        switch kind {
        case .keyword: return .pink
        case .string: return .green
        case .comment: return .secondary
        case .number: return .orange
        case .plain: return .primary
        }
    }
}
