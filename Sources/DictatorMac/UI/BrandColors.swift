import SwiftUI

extension Color {
    /// Pinned brand blue used wherever the user's system accent would
    /// otherwise get in the way:
    ///
    /// - Primary action buttons. macOS lets users pick Graphite as their
    ///   system accent, which renders `.borderedProminent` buttons in
    ///   neutral grey — visually indistinguishable from a disabled button.
    /// - HUD elements. The HUD's `.regularMaterial` background propagates
    ///   a vibrancy appearance that re-resolves dynamic colours based on
    ///   the window content behind the panel, so semantic colours like
    ///   `.accentColor` would otherwise drift between apps.
    static let brandBlue = Color(red: 0.039, green: 0.518, blue: 1.0) // ~#0A84FF
}
