import AppKit
import SwiftUI
import Observation

@MainActor
final class HUDController {
    private let panel: HUDPanel
    private let state: AppState
    private var visible = false
    private var observationTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
        self.panel = HUDPanel()
        let host = NSHostingView(rootView: HUDView().environment(state))
        // Default `translatesAutoresizingMaskIntoConstraints = true` plus an
        // autoresizing mask makes the host fill the panel's content rect at all
        // times. Without this, the host sized to intrinsic content and the panel
        // background leaked through around the SwiftUI shape.
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func startObserving() {
        observationTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                // Snapshot now, then wait for the next mutation of pipeline.state.
                self.update()
                await self.waitForNextChange()
            }
        }
    }

    private func waitForNextChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Box guarantees the continuation is resumed exactly once even though
            // `onChange` is invoked synchronously from the observation framework.
            let resumed = ResumedFlag()
            withObservationTracking {
                _ = state.pipeline.state
            } onChange: {
                guard resumed.markResumed() else { return }
                continuation.resume()
            }
        }
    }

    private func update() {
        let s = state.pipeline.state
        let active = s.isActive || isTerminal(s)

        if active && !visible {
            show()
        } else if !active && visible {
            hide()
        }
    }

    private func isTerminal(_ s: PipelineState) -> Bool {
        if case .done = s { return true }
        if case .failed = s { return true }
        return false
    }

    private func show() {
        positionPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = .init(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        visible = true
    }

    private func hide() {
        visible = false
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = .init(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit doesn't strictly guarantee this runs on main, so hop explicitly.
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 460, height: 96)
        panel.setContentSize(size)
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 88
        )
        panel.setFrameOrigin(origin)
    }
}

/// One-shot flag protecting against `withObservationTracking`'s onChange being invoked
/// more than once for a single observation (rare, but cheap insurance).
private final class ResumedFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func markResumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class HUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isMovableByWindowBackground = false
        // Native shadow is back ON because the SwiftUI content now uses
        // .thinMaterial in a clipped shape — macOS samples the rounded alpha
        // correctly, so the shadow follows the pill, not the panel rectangle.
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
