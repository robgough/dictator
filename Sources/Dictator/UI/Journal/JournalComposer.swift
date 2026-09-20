import AppKit
import SwiftUI

/// Writing an entry: words and photos.
///
/// Only writing. Recording lives at the foot of the sidebar — it is the
/// window's primary action and it works from any day, whereas this box is
/// about the page in front of you. Keeping them apart also means there is
/// exactly one microphone in the window, which there wasn't before.
struct JournalComposer: View {
    @Bindable var shell: JournalShellModel
    @Environment(AppState.self) private var state
    @State private var store = JournalStore.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !shell.pendingImages.isEmpty {
                pendingPhotos
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            inputRow
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            footer
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.easeOut(duration: 0.16), value: shell.pendingImages)
        .onChange(of: shell.focusRequests) { focused = true }
    }

    /// Type size of the box, and the height of it holding a single line. The
    /// photo button and Save are pinned to that same height so the row lines up
    /// exactly rather than nearly — bottom-aligning three controls of three
    /// different natural heights is what left Save sitting low.
    private static let fontSize: CGFloat = 14
    private static let fieldPadding: CGFloat = 7
    private var rowHeight: CGFloat {
        GrowingTextBox.singleLineHeight(fontSize: Self.fontSize) + Self.fieldPadding * 2
    }

    private var inputRow: some View {
        // Bottom-aligned so that as the box grows upwards, the buttons stay put
        // on the line you're writing.
        HStack(alignment: .bottom, spacing: 8) {
            iconButton("photo.badge.plus", size: 15, help: "Add a photo…", action: addPhotos)
                .frame(height: rowHeight)

            GrowingTextBox(text: $shell.draft,
                           placeholder: placeholder,
                           focus: $focused,
                           fontSize: Self.fontSize,
                           minLines: 1,
                           maxLines: 12)
                .padding(.horizontal, 5)
                .padding(.vertical, Self.fieldPadding)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10))

            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .tint(Color.hudMint)
                .frame(height: rowHeight)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save this entry (⌘↩)")
                .disabled(!canSave)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "book.closed")
                .font(.system(size: 9))
            Text(destination)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text("\(hotkeyHint) from any app")
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var pendingPhotos: some View {
        FlowRow(spacing: 6) {
            ForEach(shell.pendingImages, id: \.self) { url in
                HStack(spacing: 4) {
                    Image(systemName: "photo")
                        .font(.system(size: 9))
                    Text(url.lastPathComponent)
                        .font(.system(size: 10))
                        .lineLimit(1)
                    Button {
                        shell.pendingImages.removeAll { $0 == url }
                    } label: {
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
        }
    }

    // MARK: - Doing things

    private var canSave: Bool {
        !shell.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !shell.pendingImages.isEmpty
    }

    /// A photo with nothing said about it is allowed — the nudge is the
    /// placeholder, not a refusal. Most of the time a picture in a journal is
    /// there because of something that happened, and the sentence is the point.
    private var placeholder: String {
        shell.pendingImages.isEmpty ? "Write something…" : "Say something about this…"
    }

    private func save() {
        let text = shell.draft
        let images = shell.pendingImages
        shell.draft = ""
        shell.pendingImages = []
        Task { await store.add(text: text, images: images) }
    }

    private func addPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        shell.pendingImages.append(contentsOf: panel.urls)
        focused = true
    }

    private func iconButton(_ symbol: String,
                            size: CGFloat,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Text

    private var destination: String {
        guard let url = try? JournalWriter.resolvedURL(
            pathTemplate: state.settings.journalPathTemplate) else {
            return "No journal file is set"
        }
        return url.lastPathComponent
    }

    private var hotkeyHint: String {
        state.settings.journalTriggerMode == .keyboardShortcut
            ? "The journal hotkey works"
            : "The journal trigger works"
    }
}
