import AppKit
import SwiftUI
import Observation

/// Owns the island panel — successor to the retired `HUDController`, same
/// observation loop and key-monitor plumbing, now serving two tenants:
///
///   - the dictation pipeline (transient states, follows the mouse screen —
///     it appears where the user's attention is when they hit the hotkey);
///   - the meeting coach (persistent ambient strip, pinned to the screen
///     that was active when the recording started — a long-lived strip that
///     chased the cursor across displays would be noise).
///
/// Dictation takes the surface while active; the coach strip resumes after.
/// All visual morphing happens inside `IslandView`'s springs — this
/// controller only shows/hides/repositions the fixed-size panel.
@MainActor
final class IslandController {
    private let panel: IslandPanel
    private let state: AppState
    private let context = IslandContext()
    private var observationTask: Task<Void, Never>?

    /// The screen the coach strip is pinned to for the current meeting.
    /// Captured when the engine first appears, cleared with it.
    private var pinnedCoachScreen: NSScreen?

    /// Escape-to-cancel while the pipeline is cancellable; Tab cycles the
    /// dictation mode during `.recording`. Carried over from HUDController
    /// unchanged, including the tight lifecycle gating.
    private let escapeMonitor = EscapeCancelMonitor()
    private var escapeActive = false
    private let recordingMonitor = RecordingKeyMonitor()
    private var recordingMonitorActive = false

    init(state: AppState) {
        self.state = state
        self.panel = IslandPanel()
        let host = NSHostingView(rootView: IslandView(context: context).environment(state))
        // Fill the panel's content rect at all sizes (the SwiftUI shape
        // inside does its own sizing against this canvas).
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        // The panel lives on screen permanently: tucked, it's fully
        // invisible (transparent window, shape parked above the screen
        // edge, mouse-transparent), and never ordering it out is what makes
        // the emergence animation reliable — an orderOut/orderFront cycle
        // rebuilds the window's layer tree, and Core Animation renders
        // changes against freshly attached layers at their final values
        // (the "reveal only animated the first time" bug). With the window
        // always present, the tucked frame is always the committed state
        // for the spring to depart from.
        position(on: activeScreen())
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    private func startObserving() {
        observationTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                self.update()
                await self.waitForNextChange()
            }
        }
    }

    private func waitForNextChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumedFlag()
            withObservationTracking {
                // Everything that changes show/hide, screen, or mouse policy.
                // The 1 Hz snapshot and nudge churn are deliberately NOT read
                // here — IslandView observes those itself; the controller
                // only reacts to structural changes.
                _ = self.state.pipeline.state
                _ = self.state.activeCoachEngine
                _ = self.state.activeCoachEngine?.chipHidden
                _ = self.state.settings.meetingCoachChipEnabled
                _ = self.context.coachExpanded
            } onChange: {
                guard resumed.markResumed() else { return }
                continuation.resume()
            }
        }
    }

    private func update() {
        let s = state.pipeline.state
        let dictationActive = s.isActive || isTerminal(s)

        let engine = state.activeCoachEngine
        if engine == nil {
            pinnedCoachScreen = nil
        } else if pinnedCoachScreen == nil {
            // First sight of this meeting's engine — pin the coach strip to
            // the screen the user is on right now (recording just started).
            pinnedCoachScreen = activeScreen()
        }
        let coachVisible = engine != nil
            && engine?.chipHidden != true
            && state.settings.meetingCoachChipEnabled
        context.coachVisible = coachVisible

        // The expanded checklist collapses whenever the coach loses the
        // surface — dictation taking over, the strip hiding, meeting end.
        if context.coachExpanded, !coachVisible || dictationActive {
            context.coachExpanded = false
        }
        // Key-window status only while the quick-add field could need
        // typing (ScratchpadPanel's nonactivating+key pattern).
        let wantsKey = context.coachExpanded
        if panel.allowsKey != wantsKey {
            panel.allowsKey = wantsKey
            if wantsKey {
                panel.makeKey()
            } else if panel.isKeyWindow {
                panel.resignKey()
            }
        }

        // Mouse policy: transparent unless something is clickable — the
        // pipeline's hover-cancel, or the coach strip (tap to expand,
        // checklist interactions, context menu).
        panel.ignoresMouseEvents = !(s.canCancel || (coachVisible && !dictationActive))

        // Escape monitor: only while the pipeline is cancellable.
        if s.canCancel && !escapeActive {
            escapeMonitor.start { [weak self] in
                self?.state.pipeline.cancelInFlight()
            }
            escapeActive = true
        } else if !s.canCancel && escapeActive {
            escapeMonitor.stop()
            escapeActive = false
        }

        // Tab mode-cycling: gated tightly to `.recording`.
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

        // Dictation follows the mouse; the coach holds its pinned screen.
        let targetScreen = dictationActive ? activeScreen() : pinnedCoachScreen ?? activeScreen()
        let shouldShow = dictationActive || coachVisible

        // Stateless reconciliation: the desired visibility is compared
        // against `context.revealed` itself — no separate bookkeeping flag
        // to desync. If an intermediate state change is ever missed (the
        // observation loop's registration gap), the next update self-heals.
        if shouldShow {
            position(on: targetScreen)
        }
        if shouldShow != context.revealed {
            if shouldShow { show() } else { hide() }
        }
    }

    private func isTerminal(_ s: PipelineState) -> Bool {
        if case .done = s { return true }
        if case .failed = s { return true }
        return false
    }

    /// Reveal: a touch of spring overshoot (the "pop" — the shape's top
    /// bleed absorbs it). Retract: a quick clean tuck; bounce on the way
    /// out reads as hesitation.
    private static let revealSpring = Animation.spring(response: 0.55, dampingFraction: 0.70)
    private static let retractSpring = Animation.spring(response: 0.36, dampingFraction: 1.0)

    private func show() {
        // Re-assert cross-Space behavior + z-order every show — macOS
        // sometimes binds a panel to one Space and ignores the flags later
        // (see HUDPanel's history). The panel is already on screen; this
        // just refreshes its standing.
        panel.collectionBehavior = IslandPanel.crossSpaceBehavior
        panel.orderFrontRegardless()
        // The observable mutation carries the transaction — IslandView's
        // offset animates with it. No sequencing needed: the window is
        // always on screen, so the tucked "from" frame is already the
        // committed state.
        withAnimation(Self.revealSpring) {
            context.revealed = true
        }
    }

    private func hide() {
        withAnimation(Self.retractSpring) {
            context.revealed = false
        }
    }

    /// Anchor the canvas top-centre, flush with the screen's top edge, and
    /// hand the screen's notch geometry to the view. No-op when nothing
    /// changed (this runs on every structural update).
    private func position(on screen: NSScreen?) {
        guard let screen else { return }
        let size = IslandPanel.canvasSize
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let geometry = NotchGeometry.of(screen)
        if context.geometry != geometry { context.geometry = geometry }
    }

    /// Mouse-cursor screen, the most reliable "where is the user looking"
    /// signal for an accessory app with no key window (HUDController's
    /// rationale, carried over).
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSPointInRect(mouse, $0.frame) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

/// One-shot flag protecting against `withObservationTracking`'s onChange
/// firing more than once per observation (rare, but cheap insurance).
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
