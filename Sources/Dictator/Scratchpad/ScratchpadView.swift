import SwiftUI

/// The Scratchpad's content: a slim header and a full-height plain-text editor
/// over `.regularMaterial`, clipped to a rounded card so the panel's shadow
/// hugs the outline. v1 is plain text; the file on disk is Markdown.
struct ScratchpadView: View {
    let model: ScratchpadModel
    var onClose: () -> Void

    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            TextEditor(text: editorBinding)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .focused($editorFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        // First open focuses via onAppear; subsequent opens via the controller's
        // focusPulse bump, since onAppear won't fire again for a reused host.
        .onAppear { editorFocused = true }
        .onChange(of: model.focusPulse) { _, _ in editorFocused = true }
    }

    /// Writes that flow through the editor schedule a debounced save. A direct
    /// `model.text` assignment (e.g. `reload()`) bypasses this setter, so
    /// re-opening the panel never re-writes the contents it just loaded.
    private var editorBinding: Binding<String> {
        Binding(
            get: { model.text },
            set: { model.text = $0; model.scheduleSave() }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandBlue)
            Text("Scratchpad")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
