import AppKit

/// Borderless floating panel hosting the Scratchpad. Like `HUDPanel` it floats
/// above other apps (`.statusBar` level) and follows the user across Spaces.
/// Unlike the HUD, it's an editor — it must accept keyboard input — so
/// `canBecomeKey` is `true`.
///
/// The `.nonactivatingPanel` style is the load-bearing bit: it lets the panel
/// become key and receive typing *without* making Dictator the active
/// application. The user keeps their place in whatever app they were in; the
/// Scratchpad just floats in front and takes the keystrokes.
final class ScratchpadPanel: NSPanel {
    /// Same cross-Space recipe as `HUDPanel.crossSpaceBehavior` — re-applied on
    /// every show because macOS occasionally binds a panel to the Space it
    /// first appeared on and ignores the flags set at init.
    static let crossSpaceBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
    ]

    /// Invoked when the user presses Escape while the panel is key. Wired by
    /// the controller to slide the panel away (and flush a save).
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = Self.crossSpaceBehavior
        isMovableByWindowBackground = false
        // SwiftUI clips the content to a rounded rect, so the native window
        // shadow follows the card outline rather than the panel rectangle.
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    // Borderless panels are non-key by default. The Scratchpad is an editor, so
    // it must be able to become key to receive typing — the non-activating
    // style means it does so without stealing foreground from the user's app.
    override var canBecomeKey: Bool { true }

    // Esc → close. NSTextView maps Escape to `cancelOperation(_:)`, which walks
    // up the responder chain to the window when the text view doesn't consume
    // it — so we catch it here and hand off to the controller.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
