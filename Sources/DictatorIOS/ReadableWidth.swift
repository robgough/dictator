import SwiftUI

/// Keeps a phone-shaped layout phone-shaped on a wide window.
///
/// The app runs on iPhone, the iPhone Duo (regular width when open) and
/// iPad, in any orientation, including iPad split view, Slide Over and
/// floating windows. On a regular-width window a transcript card and two
/// record buttons would otherwise spread across the whole screen, so the
/// content is held to a readable column and centred; on compact width
/// (iPhone in portrait, the Duo's outer display, a narrow iPad window) this
/// does nothing.
///
/// Keyed on the size class rather than the device, deliberately: idiom,
/// orientation and `UIScreen.main` checks are all wrong for a window that
/// can be resized or folded, and the horizontal size class is the signal
/// that tracks the window's actual width live.
private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    let background: Color?
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .background(background ?? .clear)
        } else {
            content
        }
    }
}

extension View {
    /// See `ReadableWidth`. Pass the list's own background for grouped lists,
    /// so the margins either side don't show a different colour.
    func readableWidth(_ maxWidth: CGFloat = 700, background: Color? = nil) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth, background: background))
    }
}
