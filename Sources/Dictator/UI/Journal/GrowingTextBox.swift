import AppKit
import SwiftUI

/// A text box that takes newlines and grows as you write.
///
/// `TextField(axis: .vertical)` looks like the right thing and isn't: on macOS
/// Return submits rather than inserting a line break, so a journal entry could
/// only ever be one paragraph. `TextEditor` takes Return properly but has no
/// placeholder and no idea how tall it should be — it just fills whatever it's
/// given.
///
/// So: a `TextEditor` whose height is measured from the text itself, clamped
/// between one line and a sensible maximum, after which it scrolls. The
/// measurement uses the same font and the same available width as the editor,
/// which is what keeps the box exactly as tall as what's in it.
struct GrowingTextBox: View {
    @Binding var text: String
    let placeholder: String
    /// Passed in rather than owned: focus belongs to the row this sits in, and
    /// `.focused` has to land on the editor itself to work.
    var focus: FocusState<Bool>.Binding
    var fontSize: CGFloat = 14
    var minLines: Int = 1
    var maxLines: Int = 12

    @State private var measured: CGFloat?
    @State private var width: CGFloat = 0

    /// `TextEditor` puts its text container's line-fragment padding either
    /// side. The placeholder and the measurement both have to account for it or
    /// they sit a few points off the real text.
    private static let textInset: CGFloat = 5

    /// The height of one line at this size, so whatever sits beside the box can
    /// line up with it exactly instead of nearly.
    static func singleLineHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private var font: NSFont { .systemFont(ofSize: fontSize) }
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
    private var minHeight: CGFloat { lineHeight * CGFloat(minLines) }
    private var maxHeight: CGFloat { lineHeight * CGFloat(maxLines) }

    private var height: CGFloat {
        min(max(measured ?? minHeight, minHeight), maxHeight)
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .focused(focus)
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, Self.textInset)
                        .allowsHitTesting(false)
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width; remeasure() }
                        .onChange(of: proxy.size.width) { _, new in
                            width = new
                            remeasure()
                        }
                }
            }
            .onChange(of: text) { _, _ in remeasure() }
    }

    private func remeasure() {
        guard width > 0 else { return }
        measured = Self.height(of: text, width: width, font: font, lineHeight: lineHeight)
    }

    /// Height of `text` laid out in `width`, in points.
    ///
    /// A trailing newline is added back by hand: `boundingRect` measures the
    /// glyphs, and an empty last line has none — so without this the box
    /// refuses to grow at the exact moment you press Return, which is the one
    /// moment you're looking for it to.
    private static func height(of text: String,
                               width: CGFloat,
                               font: NSFont,
                               lineHeight: CGFloat) -> CGFloat {
        let available = max(width - textInset * 2, 1)
        let body = text.isEmpty ? " " : text
        let attributed = NSAttributedString(string: body, attributes: [.font: font])
        let bounding = attributed.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        var height = ceil(bounding.height)
        if body.hasSuffix("\n") { height += lineHeight }
        return height
    }
}
