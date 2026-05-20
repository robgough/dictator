import AppKit
import SwiftUI
import Observation

@MainActor
final class HUDController {
    private let panel: HUDPanel
    private let state: AppState
    private var visible = false
    private var observationTask: Task<Void, Never>?
    /// Listens for Escape while the pipeline is in a cancellable state, then
    /// routes a press to the same `cancelInFlight()` path the HUD's
    /// hover-cancel button uses. Lifecycle is gated on `canCancel` so we
    /// don't quietly listen for Escape while idle.
    private let escapeMonitor = EscapeCancelMonitor()
    private var escapeActive = false
    /// Listens for Tab during `.recording` and cycles the active DictationMode.
    /// Lifecycle is gated to `.recording` only — outside recording, cycling
    /// has nothing to act on, and we don't want to consume Tab events the
    /// user is intentionally sending elsewhere.
    private let recordingMonitor = RecordingKeyMonitor()
    private var recordingMonitorActive = false

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

        // The panel is mouse-transparent by default so clicks pass through to
        // whatever's underneath. Flip that off only while the state is
        // cancellable, so the hover overlay can actually receive mouse events
        // for the cancel button.
        panel.ignoresMouseEvents = !s.canCancel

        // Mirror the same cancellable window with the Escape-key monitor —
        // installed only while there's something to cancel, torn down as
        // soon as we're back to idle / done / failed.
        if s.canCancel && !escapeActive {
            escapeMonitor.start { [weak self] in
                self?.state.pipeline.cancelInFlight()
            }
            escapeActive = true
        } else if !s.canCancel && escapeActive {
            escapeMonitor.stop()
            escapeActive = false
        }

        // Mode-cycling monitor: gated tightly to `.recording`. We don't want
        // to consume Tab during warmup, transcription, or assistant flows.
        let isRecording: Bool = { if case .recording = s { return true } else { return false } }()
        if isRecording && !recordingMonitorActive {
            recordingMonitor.start { [weak self] in
                self?.state.pipeline.cycleMode()
            }
            recordingMonitorActive = true
        } else if !isRecording && recordingMonitorActive {
            recordingMonitor.stop()
            recordingMonitorActive = false
        }

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
        guard positionPanel() else { return }
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

    /// Returns false if no screen at all is resolvable, so `show()` can bail
    /// instead of ordering the panel front at a stale (often off-screen) frame.
    private func positionPanel() -> Bool {
        guard let screen = activeScreen() else { return false }
        let size = NSSize(width: 460, height: 96)
        panel.setContentSize(size)
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 88
        )
        panel.setFrameOrigin(origin)
        return true
    }

    /// `NSScreen.main` is defined as "the screen containing the key window",
    /// which is unreliable for an `.accessory` app with no key window of its
    /// own — particularly when the foreground app is fullscreen on a
    /// secondary display, or during space transitions, where it can return
    /// the wrong screen or nil. The mouse cursor is the most reliable signal
    /// of which screen the user is looking at when they hit a hotkey, so
    /// prefer that; fall back through the rest only if cursor resolution
    /// somehow fails.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
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
