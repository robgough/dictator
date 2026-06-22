import AppKit
import SwiftUI

/// Owns the Scratchpad panel, its SwiftUI host, and the editor model, and
/// drives the slide-in / slide-out from the right edge of the active screen.
///
/// Created once at launch (by `AppDelegate`) and kept for the app's lifetime;
/// the global hotkey calls `toggle()`. The panel and its host are reused across
/// opens — only the text is reloaded — so toggling is cheap.
@MainActor
final class ScratchpadController: NSObject, NSWindowDelegate {
    private let panel = ScratchpadPanel()
    private let model = ScratchpadModel()
    private var visible = false

    /// Gap kept from the screen edges. Width comes from the user's setting.
    private let margin: CGFloat = 16

    override init() {
        super.init()
        // Point the model at the synced folder before anything reads it. The
        // store used to resolve `SyncedStorage.fileURL` on every load/save;
        // now (shared with iOS) it's bootstrapped with an explicit directory,
        // re-pointed via `relocate(to:)` when the user changes synced folders.
        model.bootstrap(customDirectory: SyncedStorage.directory)
        let host = NSHostingView(
            rootView: ScratchpadView(model: model, onClose: { [weak self] in self?.hide() })
        )
        // Fill the panel's content rect at all sizes (see HUDController for why
        // the autoresizing mask matters with NSHostingView).
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
    }

    /// The global hotkey's action.
    func toggle() {
        if visible { hide() } else { show() }
    }

    func show() {
        guard let screen = activeScreen() else { return }
        // Reload from disk so edits made on another device since this panel was
        // last open show up. Safe — we flush on hide / resign-key, so anything
        // typed here is already persisted by the time we're hidden.
        model.reload()

        let final = cardFrame(on: screen)
        // Start just off the right edge so the card slides in from outside.
        let start = NSRect(
            origin: NSPoint(x: screen.visibleFrame.maxX + 8, y: final.origin.y),
            size: final.size
        )

        panel.collectionBehavior = ScratchpadPanel.crossSpaceBehavior
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        // Re-assert editor focus for this open (onAppear only fires once).
        model.focusPulse += 1

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = .init(name: .easeOut)
            panel.animator().setFrame(final, display: true)
            panel.animator().alphaValue = 1
        }
        visible = true
    }

    /// Animate to the current width setting when the user changes it in Settings
    /// while the panel is open. No-op when it's hidden — the next open picks up
    /// the new width anyway.
    func relayoutIfVisible() {
        guard visible, let screen = activeScreen() else { return }
        let frame = cardFrame(on: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = .init(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// The on-screen card frame for the current width setting — full height with
    /// an edge margin, pinned to the right. Width is clamped to the screen so
    /// "Large" can't run off a small display.
    private func cardFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let maxWidth = vf.width - margin * 2
        let width = min(CGFloat(AppState.shared.settings.scratchpadWidth.points), maxWidth)
        let height = vf.height - margin * 2
        let origin = NSPoint(x: vf.maxX - width - margin, y: vf.minY + margin)
        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }

    func hide() {
        guard visible else { return }
        visible = false
        model.saveNow()

        let panel = self.panel
        // Slide back out past the right edge of wherever it currently sits.
        let target = NSPoint(x: panel.frame.maxX + 24, y: panel.frame.origin.y)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = .init(name: .easeIn)
            panel.animator().setFrameOrigin(target)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit doesn't guarantee this hop is on main, so be explicit.
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    /// Flush any pending edit. Called at app termination, where neither the
    /// debounce nor resign-key is guaranteed to have fired.
    func flush() {
        model.saveNow()
    }

    /// Re-point the note at a new synced folder. Called from Settings when the
    /// user picks a different synced directory; `SyncedStorage.relocateContents`
    /// has already copied `scratchpad.md` across, so bootstrap flushes any
    /// pending edit to the old location, then reloads from the new one.
    func relocate(to directory: URL) {
        model.bootstrap(customDirectory: directory)
    }

    // The panel losing key focus (the user clicked into another app) is a good
    // moment to flush — it covers the "typed, then quit via the other app" path
    // that the close/terminate hooks might miss. We deliberately do NOT hide on
    // resign-key: the Scratchpad stays pinned until the user dismisses it.
    func windowDidResignKey(_ notification: Notification) {
        model.saveNow()
    }

    /// The screen the user is most likely looking at — the one under the cursor,
    /// which is more reliable than `NSScreen.main` for an accessory app with no
    /// key window of its own. Mirrors `HUDController.activeScreen()`.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
