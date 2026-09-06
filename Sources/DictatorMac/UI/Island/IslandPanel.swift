import AppKit

/// The notch island's window — successor to the retired `HUDPanel`, same
/// load-bearing recipe: borderless non-activating panel at `.statusBar`
/// level (above the menu bar), joining every Space including fullscreen
/// ones, never stealing key/main.
///
/// The panel itself is a fixed-size transparent canvas anchored to the top
/// of the screen; all visible motion is the SwiftUI shape inside springing
/// between sizes. We never animate the NSWindow frame — window-frame
/// animation is jankier and AppKit window re-layout under churn has bitten
/// this codebase before (the 2026-06-07 `_postWindowNeedsUpdateConstraints`
/// crash).
final class IslandPanel: NSPanel {
    /// Maximum footprint of any island state — the canvas the shape moves in.
    static let canvasSize = NSSize(width: 600, height: 220)

    /// Cross-Space recipe carried over verbatim from `HUDPanel`: re-applied
    /// before every order-front because macOS occasionally binds a panel to
    /// the Space it first appeared on and ignores the flags afterwards.
    /// `.stationary` stays deliberately omitted (it has anchored the panel
    /// to the launch Space when combined with `.canJoinAllSpaces`).
    static let crossSpaceBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
    ]

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = Self.crossSpaceBehavior
        isMovableByWindowBackground = false
        // No native shadow: the canvas is mostly empty, and macOS would draw
        // the shadow for the full rect. The SwiftUI shape carries its own.
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    /// Granted only while the coach's expanded checklist needs its quick-add
    /// field — the ScratchpadPanel pattern: `.nonactivatingPanel` + key means
    /// typing lands here without Dictator becoming the active app or the
    /// user's window losing foreground. The controller flips this with the
    /// expanded state and resigns key on collapse.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
