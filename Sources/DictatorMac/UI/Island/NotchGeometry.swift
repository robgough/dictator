import AppKit

/// Per-screen facts the island needs to anchor itself: whether this screen
/// has a camera-housing notch, how wide it is, and how far content must drop
/// to clear the top obstruction (notch or menu bar).
///
/// On notched screens the island renders flush to the top edge and at least
/// as wide as the notch, so the black shape and the physical housing read as
/// one object — content lives below `topInset`. On plain screens there's
/// nothing to merge with: transient dictation states still sit flush-top
/// (briefly covering the menu bar is fine), but the long-lived coach strip
/// drops below the menu bar so it doesn't sit over the clock for an hour.
struct NotchGeometry: Equatable {
    let hasNotch: Bool
    /// Physical notch width; 0 on plain screens.
    let notchWidth: CGFloat
    /// Height of the top obstruction — the camera housing on notched screens
    /// (safeAreaInsets.top), the menu bar on plain ones. 0 in fullscreen on
    /// plain screens (menu bar hidden — visibleFrame reaches the top).
    let topInset: CGFloat

    static func of(_ screen: NSScreen) -> NotchGeometry {
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0 {
            // Notched: the auxiliary areas flank the housing; what's missing
            // between them is the notch itself.
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let notch = max(0, screen.frame.width - left - right)
            return NotchGeometry(hasNotch: true, notchWidth: notch, topInset: safeTop)
        }
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        return NotchGeometry(hasNotch: false, notchWidth: 0, topInset: menuBar)
    }
}
