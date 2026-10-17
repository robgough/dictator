import SwiftUI

/// Keeps a phone-shaped layout phone-shaped on a wide screen.
///
/// Every iPhone so far has been compact-width in portrait, so the app's
/// layouts stretch edge to edge. The iPhone Duo's inner display is regular
/// width *and* height — and ignores the app's portrait-only lock — so a
/// transcript card and two record buttons would otherwise spread across
/// ~7.8 inches. On regular width the content is held to a readable column
/// and centred; on compact width (every other iPhone, and the Duo's outer
/// display) this does nothing.
///
/// Keyed on the size class rather than the device, deliberately: Apple's
/// guidance for the Duo is that idiom, orientation and `UIScreen.main`
/// checks are all wrong there, and the size class is the one signal that
/// tracks folding and unfolding live.
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
