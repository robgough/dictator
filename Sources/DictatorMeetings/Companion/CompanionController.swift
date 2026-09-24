import AppKit
import SwiftUI

/// The companion: a small floating panel shown beside the call while a
/// meeting records, so the window can stay out of the way.
///
/// A regular floating `NSPanel` rather than the notch island's always-present
/// canvas: this one has a real size, is dragged about by the user and needs
/// to take typing for the quick-note field, and it has no reveal spring to
/// protect — so it's simply ordered in and out. It becomes key only when a
/// control inside it needs to be (`becomesKeyOnlyIfNeeded`), so clicking it
/// never takes focus away from the call.
///
/// Its height follows its content — notes and key points come and go during
/// a call — but NOT through the hosting controller's `preferredContentSize`.
/// That drove the window frame from inside layout: the resize invalidated the
/// (hidden) title bar's safe area, which asked for another layout pass, until
/// AppKit ran out of passes and threw. It crashed twice within minutes of a
/// recording starting. Now the panel is borderless (no title bar to have a
/// safe area), its hosting view never sizes the window, and the content
/// reports its height, which the controller applies on the next turn of the
/// run loop — outside layout, keeping the top edge where the user put it.
@MainActor
final class CompanionController {
    private let state: MeetingsAppState
    private var panel: CompanionPanel?
    /// The recording the panel's content was built for.
    private var shownSessionID: UUID?
    private var observationTask: Task<Void, Never>?

    init(state: MeetingsAppState) {
        self.state = state
        observationTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.update()
                await self.waitForNextChange()
            }
        }
    }

    deinit { observationTask?.cancel() }

    private func waitForNextChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = CompanionResumedFlag()
            withObservationTracking {
                // Transition-only mirrors, never `state`, which ticks 10×/s.
                _ = self.state.liveSession?.isLive
                _ = self.state.settings.meetingCompanionEnabled
                _ = self.state.companionDismissed
            } onChange: {
                guard resumed.markResumed() else { return }
                continuation.resume()
            }
        }
    }

    private func update() {
        let session = state.liveSession
        let wanted = session?.isLive == true
            && state.settings.meetingCompanionEnabled
            && !state.companionDismissed
        if wanted, let session {
            show(session)
        } else {
            hide()
        }
    }

    private func show(_ session: MeetingSession) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A new recording gets a fresh view (its own session); the panel sizes
        // itself to it. A panel the user has never moved starts at the
        // top-right of the screen they're on.
        if shownSessionID != session.id {
            let view = CompanionView(session: session) { [weak self] height in
                self?.contentHeightChanged(height)
            }
            let host = NSHostingView(rootView: AnyView(view.environment(state)))
            host.sizingOptions = []
            host.autoresizingMask = [.width, .height]
            host.frame = NSRect(origin: .zero, size: panel.frame.size)
            panel.contentView = host
            shownSessionID = session.id
        }
        if !panel.isVisible {
            if !panel.setFrameUsingName(Self.frameName) { placeTopRight(panel) }
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Resize to the content's height, after the layout pass that measured it
    /// — never during one — pinning the top edge.
    private func contentHeightChanged(_ height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panel else { return }
            let target = ceil(height)
            guard target > 0, abs(panel.frame.height - target) > 1 else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - target
            frame.size.height = target
            panel.setFrame(frame, display: true)
        }
    }

    private static let frameName = "DictatorMeetingsCompanion"

    private func makePanel() -> CompanionPanel {
        let panel = CompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: CompanionView.width, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private func placeTopRight(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24))
    }
}

/// A floating panel that can take typing (for the quick-note field) without
/// activating the app — the call stays the frontmost app.
final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CompanionResumedFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func markResumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
