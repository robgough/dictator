import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A file the assistant wrote, shown in the transcript as an artefact rather
/// than a sentence about a path.
///
/// The point is that the user decides what happens to it. Writing everything
/// into one folder is what keeps the model from choosing where files land —
/// but that folder is Dictator's answer, not the user's, so the card is where
/// they redirect it: read it, copy it, open it, or put it where they actually
/// wanted it.
///
/// Contents are read from disk each time rather than cached with the message.
/// The file is the real thing, it lives in the user's own folder, and they may
/// well have edited it since — a transcript showing what *was* written after
/// they changed it would be quietly wrong.
struct ChatFileCard: View {
    let file: ProducedFile

    @State private var expanded = true
    @State private var copied = false
    @State private var savedTo: String?

    private static let previewByteLimit = 256 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, file.stillExists {
                Divider()
                preview
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.quaternary.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                .resizable()
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.stillExists {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No longer on disk — it was moved or deleted.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if file.stillExists {
                actions
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if file.stillExists { expanded.toggle() } }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            iconButton(copied ? "checkmark" : "doc.on.doc",
                       help: "Copy the contents",
                       tint: copied ? .green : .secondary,
                       action: copy)
            iconButton("square.and.arrow.down", help: "Save a copy elsewhere…",
                       action: exportCopy)
            iconButton("arrow.up.forward.app", help: "Open", action: open)
            iconButton("folder", help: "Show in Finder", action: reveal)
            iconButton(expanded ? "chevron.up" : "chevron.down",
                       help: expanded ? "Hide the contents" : "Show the contents") {
                expanded.toggle()
            }
        }
    }

    private func iconButton(
        _ symbol: String, help: String, tint: Color = .secondary, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var preview: some View {
        let contents = read()
        if contents.isEmpty {
            Text("Empty file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        } else if isMarkdown {
            // Markdown is the common case and worth rendering properly —
            // headings, lists and any fenced code inside it.
            ScrollView {
                ChatMarkdownView(text: contents)
                    .padding(10)
            }
            .frame(maxHeight: 320)
        } else {
            // Everything else is shown as source, which is what it is.
            ChatMarkdownView(text: "```\(file.fileExtension)\n\(contents)\n```")
                .padding(10)
        }
    }

    private var isMarkdown: Bool {
        file.fileExtension == "md" || file.fileExtension == "markdown"
    }

    private var subtitle: String {
        var parts = [file.sizeDescription]
        parts.append("in this chat's folder")
        if let savedTo { parts.append("copied to \(savedTo)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// Bounded: a card is a preview, and reading an unexpectedly huge file into
    /// the view would stall the window.
    private func read() -> String {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: Self.previewByteLimit)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(read(), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func open() {
        NSWorkspace.shared.open(file.url)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Saves a snapshot elsewhere. The chat keeps its own copy.
    ///
    /// A copy, not a move — this was wrong the other way round first. The
    /// chat's folder is its *working* directory, not a staging area: the
    /// assistant may be asked to change the file again, and it can only do
    /// that to a file it still has. What you take out is a point-in-time
    /// export, and its going stale when the conversation moves on is exactly
    /// what an export is for.
    private func exportCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: file.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: file.url, to: destination)
                savedTo = destination.deletingLastPathComponent().lastPathComponent
            } catch {
                NSLog("[Dictator] Couldn't save a copy: \(error.localizedDescription)")
            }
        }
    }

}
