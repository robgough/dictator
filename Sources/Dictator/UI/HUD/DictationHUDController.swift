import AppKit
import SwiftUI
import Observation

/// Owns the dictation HUD panel — one panel, one observation loop, three
/// looks. `HUDStyle` picks the look: the notch island (top-centre, flush
/// with the screen edge, sliding out from behind it) or one of the two
/// bottom-anchored compact styles (popping up just above the Dock). This
/// controller only positions the fixed-size canvas and flips
/// `context.revealed`; every visual difference lives in the SwiftUI views
/// (`IslandView`, `CompactHUDView`) that `DictationHUDRootView` switches
/// between.
///
/// Successor to `IslandController` (itself the successor to the retired
/// `HUDController`) — the key-monitor plumbing is carried over.
/// Dictator Meetings runs its own `CoachIslandController` over the same
/// shared `IslandPanel`.
@MainActor
final class DictationHUDController {
    private let panel: IslandPanel
    private let state: AppState
    private let context = HUDContext()
    private var observationTask: Task<Void, Never>?
    /// The style the panel is currently positioned for. Compared against the
    /// setting on every update so a change in Settings moves the (tucked,
    /// invisible) panel to its new home straight away, not on the next
    /// dictation.
    private var positionedStyle: HUDStyle?

    /// Escape-to-cancel while the pipeline is cancellable; Tab cycles the
    /// dictation mode during `.recording`. Both swallow the key so it never
    /// reaches the app being dictated into (see `KeyInterceptMonitor`); the
    /// tight lifecycle gating below keeps the intercept window short.
    private let escapeMonitor = KeyInterceptMonitor(key: .escape, fallback: .passiveGlobalMonitor, localPolicy: .passThrough)
    private var escapeActive = false
    private let recordingMonitor = KeyInterceptMonitor(key: .tab, fallback: .off, localPolicy: .swallow)
    private var recordingMonitorActive = false

    init(state: AppState) {
        self.state = state
        self.panel = IslandPanel()
        let host = NSHostingView(rootView: DictationHUDRootView(context: context).environment(state))
        // Fill the panel's content rect at all sizes (the SwiftUI shape
        // inside does its own sizing against this canvas).
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        // The panel lives on screen permanently: tucked, it's fully
        // invisible (transparent window, shape parked out of view,
        // mouse-transparent), and never ordering it out is what makes the
        // reveal animation reliable — an orderOut/orderFront cycle rebuilds
        // the window's layer tree, and Core Animation renders changes
        // against freshly attached layers at their final values (the
        // "reveal only animated the first time" bug). With the window
        // always present, the tucked state is always the committed state
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
                // Everything that changes show/hide, screen, placement or
                // mouse policy. The 1 Hz snapshot and nudge churn are
                // deliberately NOT read here — the views observe those
                // themselves; the controller only reacts to structural
                // changes.
                _ = self.state.pipeline.state
                _ = self.state.settings.hudStyle
            } onChange: {
                guard resumed.markResumed() else { return }
                continuation.resume()
            }
        }
    }

    private func update() {
        let s = state.pipeline.state
        let dictationActive = s.isActive || isTerminal(s)

        // The dictation HUD never needs key-window status — nothing on it
        // takes typed input.
        if panel.allowsKey {
            panel.allowsKey = false
            if panel.isKeyWindow { panel.resignKey() }
        }

        // Mouse policy: transparent unless the pipeline's hover-cancel target
        // is live.
        panel.ignoresMouseEvents = !s.canCancel

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

        let targetScreen = activeScreen()
        let shouldShow = dictationActive

        // A style change re-homes the panel immediately, even while tucked,
        // so the next reveal departs from the right place.
        if positionedStyle != state.settings.hudStyle {
            position(on: targetScreen)
        }

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

    /// Island reveal: a touch of spring overshoot (the "pop" — the shape's
    /// top bleed absorbs it). Retract: a quick clean tuck; bounce on the way
    /// out reads as hesitation.
    private static let revealSpring = Animation.spring(response: 0.55, dampingFraction: 0.70)
    private static let retractSpring = Animation.spring(response: 0.36, dampingFraction: 1.0)
    /// Compact styles pop rather than slide, so the reveal is shorter with a
    /// little overshoot on the scale; the dismiss is a plain quick settle.
    private static let popSpring = Animation.spring(response: 0.42, dampingFraction: 0.72)
    private static let dismissSpring = Animation.spring(response: 0.26, dampingFraction: 1.0)

    private func show() {
        // Re-assert cross-Space behavior + z-order every show — macOS
        // sometimes binds a panel to one Space and ignores the flags later
        // (see HUDPanel's history). The panel is already on screen; this
        // just refreshes its standing.
        panel.collectionBehavior = IslandPanel.crossSpaceBehavior
        panel.orderFrontRegardless()
        // The observable mutation carries the transaction — the mounted
        // view's reveal modifiers animate with it. No sequencing needed: the
        // window is always on screen, so the tucked "from" state is already
        // the committed state.
        let bottom = state.settings.hudStyle.isBottomAnchored
        withAnimation(bottom ? Self.popSpring : Self.revealSpring) {
            context.revealed = true
        }
    }

    private func hide() {
        let bottom = state.settings.hudStyle.isBottomAnchored
        withAnimation(bottom ? Self.dismissSpring : Self.retractSpring) {
            context.revealed = false
        }
    }

    /// Park the canvas for the current style and hand the screen's notch
    /// geometry to the view. Island: top-centre, flush with the screen's top
    /// edge. Compact styles: bottom-centre of the *visible* frame (above the
    /// Dock), with the shape's rest gap given by `HUDStyle.bottomInset` —
    /// the canvas itself sits `CompactHUDView.shadowBleed` lower so the
    /// shape's drop shadow has room below it. No-op when nothing changed
    /// (this runs on every structural update).
    private func position(on screen: NSScreen?) {
        guard let screen else { return }
        let style = state.settings.hudStyle
        let size = IslandPanel.canvasSize
        let origin: NSPoint
        if style.isBottomAnchored {
            let visible = screen.visibleFrame
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + CGFloat(style.bottomInset) - CompactHUDView.shadowBleed
            )
        } else {
            origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height
            )
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        let geometry = NotchGeometry.of(screen)
        if context.geometry != geometry { context.geometry = geometry }
        positionedStyle = style
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
