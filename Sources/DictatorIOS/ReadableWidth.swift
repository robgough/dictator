import SwiftUI

/// Keeps a phone-shaped layout phone-shaped on a wide window.
///
/// The app runs on iPhone, the iPhone Duo (regular width when open) and
/// iPad, in any orientation, including iPad split view, Slide Over and
/// floating windows. On a wide window a transcript card and two record
/// buttons would otherwise spread across the whole screen, so the content is
/// held to a readable column and centred. Narrower than `maxWidth` it does
/// nothing.
///
/// Keyed on the width actually available rather than the device or the size
/// class: idiom, orientation and `UIScreen.main` checks are all wrong for a
/// window that can be resized or folded, and a regular size class can still
/// be a narrow column (see `AdaptiveColumns`).
private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    let background: Color?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .background(background ?? .clear)
    }
}

extension View {
    /// See `ReadableWidth`. Pass the list's own background for grouped lists,
    /// so the margins either side don't show a different colour.
    func readableWidth(_ maxWidth: CGFloat = 700, background: Color? = nil) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth, background: background))
    }
}
