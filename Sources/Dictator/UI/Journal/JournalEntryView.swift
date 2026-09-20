import AppKit
import SwiftUI

/// One entry: the time in the margin, the words, and any photos underneath.
///
/// Editing happens in place rather than in a sheet. A journal entry is two
/// sentences most of the time, and putting a window in front of the page to fix
/// a word in it would be more ceremony than the thing being fixed.
struct JournalEntryView: View {
    let entry: JournalArchive.Entry
    @Bindable var shell: JournalShellModel

    @State private var store = JournalStore.shared
    @State private var isHovering = false
    @FocusState private var editorFocused: Bool

    private var isEditing: Bool { shell.editing?.id == entry.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(entry.time)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.hudMint)
                .frame(width: 42, alignment: .leading)
                // In the margin, as an overlay, and therefore taking no space
                // at all. These used to be a row inside the entry that appeared
                // on hover, which pushed every entry below it down the page —
                // the pointer moving over a page made the page move under the
                // pointer. An overlay can't do that, and the margin is the one
                // place on a journal page that is never covering words.
                .overlay(alignment: .topLeading) {
                    if isHovering, !isEditing {
                        gutterActions
                            .offset(y: 17)
                            .transition(.opacity)
                    }
                }

            VStack(alignment: .leading, spacing: 10) {
                if isEditing {
                    editor
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Fades the overlay in. Deliberately not an animation on the entry's
        // own content: nothing about hovering is allowed to change layout.
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Edit") { beginEditing() }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            Divider()
            Button("Open File") { NSWorkspace.shared.open(entry.fileURL) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
            }
            Divider()
            Button("Delete", role: .destructive) { shell.confirmingDelete = entry }
        }
    }

    // MARK: - Reading

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(JournalMarkdown.blocks(in: entry.text, note: entry.fileURL)) { block in
                switch block {
                case .prose(let prose):
                    ChatMarkdownView(text: prose)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                case .images(let images):
                    JournalImageGrid(images: images)
                }
            }
        }
    }

    /// Two small glyphs under the timestamp. Everything else an entry can do
    /// stays on the right-click menu — a page of entries with a row of buttons
    /// on each is a control panel, not a journal.
    private var gutterActions: some View {
        HStack(spacing: 8) {
            Button { beginEditing() } label: {
                Image(systemName: "pencil")
            }
            .help("Edit this entry")

            Button { shell.confirmingDelete = entry } label: {
                Image(systemName: "trash")
            }
            .help("Delete this entry")
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
    }

    // MARK: - Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            GrowingTextBox(text: $shell.editDraft,
                           placeholder: "Write something…",
                           focus: $editorFocused,
                           fontSize: 15,
                           minLines: 2,
                           maxLines: 24)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.hudMint.opacity(0.5)))

            // Photos are chips while editing, not pictures: the thing being
            // edited is the words, and a removed chip takes its link out of the
            // entry when this is saved. The file itself stays on disk — these
            // are the user's photographs.
            if !shell.editImages.isEmpty || !shell.editNewImages.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(shell.editImages) { ref in
                        chip(ref.alt.isEmpty ? "photo" : ref.alt) {
                            shell.editImages.removeAll { $0.id == ref.id }
                        }
                    }
                    ForEach(shell.editNewImages, id: \.self) { url in
                        chip(url.lastPathComponent) {
                            shell.editNewImages.removeAll { $0 == url }
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    addPhotos()
                } label: {
                    Label("Add Photo…", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.link)
                .font(.system(size: 11))

                Spacer(minLength: 0)

                Button("Cancel") { shell.cancelEditing() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.hudMint)
                    .disabled(!canSave)
            }
            .controlSize(.small)
        }
        .onAppear { editorFocused = true }
    }

    private var canSave: Bool {
        !shell.editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !shell.editImages.isEmpty || !shell.editNewImages.isEmpty
    }

    private func chip(_ label: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10))
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func beginEditing() {
        shell.beginEditing(entry)
    }

    private func save() {
        let prose = shell.editDraft
        let keeping = shell.editImages
        let adding = shell.editNewImages
        shell.cancelEditing()
        Task { await store.edit(entry, prose: prose, keeping: keeping, adding: adding) }
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        shell.editNewImages.append(contentsOf: panel.urls)
    }
}
