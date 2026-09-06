import AppKit
import Observation
import SwiftUI

/// Observable bridge from `CoachIslandController` (which knows the screen) to
/// the SwiftUI content (which needs the screen's notch geometry).
///
/// The counterpart to Dictator's `IslandContext`, which kept the dictation
/// fields when Meetings moved out. The two apps each run their own panel over
/// the shared `IslandPanel` / `NotchGeometry` primitives; they never share a
/// surface, because they're different processes.
@MainActor
@Observable
final class CoachIslandContext {
    var geometry = NotchGeometry(hasNotch: false, notchWidth: 0, topInset: 24)

    /// Coach strip allowed on the island right now (engine present, not
    /// hidden by the user for this meeting, setting on). The controller
    /// computes it; the view reads it.
    var coachVisible = false

    /// Drives the emergence animation: false = island tucked up behind the
    /// screen's top edge (inside the notch, where there is one), true =
    /// dropped down into view. Mutated only by the controller, inside
    /// `withAnimation` — and it doubles as the controller's source of truth
    /// for "is the island out", so there's no separate flag to desync.
    var revealed = false

    /// Coach checklist expanded on the island (click to open). The controller
    /// watches this to grant the panel key-window status while the quick-add
    /// field needs typing, and collapses it when the meeting ends.
    var coachExpanded = false
}

/// The coach island: a black shape anchored to the top-centre of the screen,
/// springing between sizes as the coach's state changes. On notched screens it
/// sits flush to the top edge at least as wide as the notch — black on black
/// with the housing, content below the camera area. On plain screens it gets
/// the identical faux-notch treatment and simply covers the empty centre of
/// the menu bar for the meeting's duration. (An earlier cut floated it as a
/// detached pill below the menu bar; in use it read as a disconnected blob.)
///
/// All motion happens here in SwiftUI — the panel never animates its frame.
struct CoachIslandView: View {
    @Environment(MeetingsAppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: CoachIslandContext

    /// The last non-hidden mode, retained so the retract animation has content
    /// to slide away — by the time we're hiding, `mode` has already gone nil.
    @State private var displayMode: Mode?

    private enum Mode: Equatable {
        case coach(nudging: Bool, expanded: Bool)
    }

    private var mode: Mode? {
        guard context.coachVisible, let engine = state.activeCoachEngine else { return nil }
        return .coach(nudging: engine.activeNudge != nil, expanded: context.coachExpanded)
    }

    /// Measured height of the current island, so the tuck offset is exactly
    /// "just past hidden" rather than the full canvas — tucking the whole
    /// canvas puts most of the spring's travel above the screen edge and the
    /// emergence reads as a blink rather than a slide.
    @State private var islandHeight: CGFloat = IslandPanel.canvasSize.height

    var body: some View {
        let geo = context.geometry

        ZStack(alignment: .top) {
            if let displayMode {
                island(for: displayMode, geo: geo)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        islandHeight = height
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: displayMode)
        .offset(y: reduceMotion || context.revealed ? 0 : -(islandHeight + 32))
        .opacity(reduceMotion && !context.revealed ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .onChange(of: mode) { _, new in
            if let new { displayMode = new }
        }
    }

    /// Extra shape height hidden above the screen edge, absorbing the reveal
    /// spring's downward overshoot so the island's top never visibly detaches
    /// from the screen edge. It sits in the window's clipped region at rest.
    private static let topBleed: CGFloat = 28

    @ViewBuilder
    private func island(for mode: Mode, geo: NotchGeometry) -> some View {
        content(for: mode)
            .frame(width: width(for: mode, geo: geo))
            .padding(.top, geo.topInset + Self.topBleed)   // clear notch / menu bar / bleed
            .background(
                CoachIslandShape()
                    .fill(.black)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
            .offset(y: -Self.topBleed)                     // park the bleed above the screen edge
    }

    @ViewBuilder
    private func content(for mode: Mode) -> some View {
        switch mode {
        case .coach:
            if let engine = state.activeCoachEngine {
                CoachIslandContent(
                    engine: engine,
                    expanded: Binding(
                        get: { context.coachExpanded },
                        set: { context.coachExpanded = $0 }
                    )
                )
            }
        }
    }

    private func width(for mode: Mode, geo: NotchGeometry) -> CGFloat {
        switch mode {
        // Expanded checklist needs working room; the nudge line needs room to
        // read; the ambient strip hugs the notch (plus a visible lip either
        // side so it registers at all).
        case .coach(_, expanded: true): max(geo.notchWidth + 56, 440)
        case .coach(nudging: true, _): max(geo.notchWidth + 56, 380)
        case .coach: max(geo.notchWidth + 56, 210)
        }
    }
}

/// Top-anchored island silhouette: square shoulders that meet the screen's top
/// edge (merging with the notch housing where there is one), rounded bottom
/// corners. A local copy of Dictator's private `IslandShape` — eight lines of
/// geometry isn't worth a shared type.
private struct CoachIslandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(18, rect.height / 2)
        return Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: 0, bottomLeading: radius,
                bottomTrailing: radius, topTrailing: 0
            )
        )
    }
}

/// Owns the coach's island panel. Lifted from Dictator's `IslandController`,
/// keeping only the coach half: a persistent ambient strip pinned to the
/// screen that was active when the recording started (a long-lived strip that
/// chased the cursor across displays would be noise), shown for as long as a
/// meeting is recording with the coach on.
///
/// Everything the dictation island needed and this doesn't — the Escape
/// cancel monitor, the Tab mode-cycler, the cancel "ear", following the mouse
/// — is gone. What stays is the load-bearing part: the panel is created once
/// and NEVER ordered out. An orderOut/orderFront cycle rebuilds the window's
/// layer tree, and Core Animation then renders changes against freshly
/// attached layers at their final values — which is the "reveal only animated
/// the first time" bug. With the window always present, the tucked frame is
/// always the committed state for the spring to depart from.
@MainActor
final class CoachIslandController {
    private let panel: IslandPanel
    private let state: MeetingsAppState
    private let context = CoachIslandContext()
    private var observationTask: Task<Void, Never>?

    /// The screen the strip is pinned to for the current meeting. Captured
    /// when the engine first appears, cleared with it.
    private var pinnedScreen: NSScreen?

    init(state: MeetingsAppState) {
        self.state = state
        self.panel = IslandPanel()
        let host = NSHostingView(rootView: CoachIslandView(context: context).environment(state))
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host
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
                // Only structural changes — the 1 Hz metric snapshot and the
                // nudge churn are observed by `CoachIslandView` itself.
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
        let engine = state.activeCoachEngine
        if engine == nil {
            pinnedScreen = nil
        } else if pinnedScreen == nil {
            // First sight of this meeting's engine — pin to the screen the
            // user is on right now (recording just started).
            pinnedScreen = activeScreen()
        }
        let coachVisible = engine != nil
            && engine?.chipHidden != true
            && state.settings.meetingCoachChipEnabled
        context.coachVisible = coachVisible

        // The expanded checklist collapses whenever the strip goes away.
        if context.coachExpanded, !coachVisible {
            context.coachExpanded = false
        }

        // Key-window status only while the quick-add field could need typing
        // (the ScratchpadPanel nonactivating+key pattern).
        let wantsKey = context.coachExpanded
        if panel.allowsKey != wantsKey {
            panel.allowsKey = wantsKey
            if wantsKey {
                panel.makeKey()
            } else if panel.isKeyWindow {
                panel.resignKey()
            }
        }

        // Clickable only while the strip is up (tap to expand, checklist
        // interactions, context menu).
        panel.ignoresMouseEvents = !coachVisible

        if coachVisible {
            position(on: pinnedScreen ?? activeScreen())
        }
        // Stateless reconciliation against `context.revealed` itself — no
        // separate bookkeeping flag to desync. A missed intermediate state
        // self-heals on the next update.
        if coachVisible != context.revealed {
            if coachVisible { show() } else { hide() }
        }
    }

    /// Reveal: a touch of spring overshoot (the "pop" — the shape's top bleed
    /// absorbs it). Retract: a quick clean tuck; bounce on the way out reads
    /// as hesitation.
    private static let revealSpring = Animation.spring(response: 0.55, dampingFraction: 0.70)
    private static let retractSpring = Animation.spring(response: 0.36, dampingFraction: 1.0)

    private func show() {
        // Re-assert cross-Space behaviour + z-order every show — macOS
        // sometimes binds a panel to one Space and ignores the flags later.
        panel.collectionBehavior = IslandPanel.crossSpaceBehavior
        panel.orderFrontRegardless()
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

    /// Mouse-cursor screen — the most reliable "where is the user looking"
    /// signal at the moment a recording starts.
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
