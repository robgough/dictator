import SwiftUI

/// Observable bridge from `IslandController` (which knows the screen) to the
/// SwiftUI content (which needs the screen's notch geometry and the coach
/// visibility verdict). The controller writes; the view reads.
@MainActor
@Observable
final class IslandContext {
    var geometry = NotchGeometry(hasNotch: false, notchWidth: 0, topInset: 24)
    /// Coach strip allowed on the island right now (engine present, not
    /// hidden, setting on). The controller computes this — the view also
    /// needs it because dictation/coach share the surface.
    var coachVisible = false
    /// Drives the emergence animation: false = island tucked up behind the
    /// screen's top edge (inside the notch, where there is one), true =
    /// dropped down into view. Mutated only by the controller, inside
    /// withAnimation — and it doubles as the controller's source of truth
    /// for "is the island out", so there's no separate flag to desync.
    var revealed = false
}

/// The island itself: a black shape anchored to the top-centre of the
/// screen, springing between sizes as content changes. On notched screens
/// it sits flush to the top edge at least as wide as the notch — black on
/// black with the housing, content below the camera area. On plain screens
/// transient dictation states still sit flush-top; the long-lived coach
/// strip drops below the menu bar as a fully-rounded pill.
///
/// All motion happens here in SwiftUI — the panel never animates its frame.
struct IslandView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: IslandContext

    /// The last non-hidden mode, retained so the retract animation has
    /// content to slide away — by the time we're hiding, `mode` itself has
    /// already gone `.hidden`.
    @State private var displayMode: Mode?

    private enum Mode: Equatable {
        case hidden
        case dictation
        case coach(nudging: Bool)
    }

    private var mode: Mode {
        let s = state.pipeline.state
        let dictationActive: Bool = {
            if s.isActive { return true }
            if case .done = s { return true }
            if case .failed = s { return true }
            return false
        }()
        if dictationActive { return .dictation }
        if context.coachVisible, let engine = state.activeCoachEngine {
            return .coach(nudging: engine.activeNudge != nil)
        }
        return .hidden
    }

    /// Measured height of the current island, so the tuck offset is exactly
    /// "just past hidden" rather than the full canvas. Tucking the full
    /// canvas height meant ~40% of the spring's travel happened above the
    /// screen edge — the shape entered view at peak velocity and the
    /// emergence read as a blink rather than a slide.
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
        // Emergence: slide up behind the screen's top edge when tucked —
        // the panel sits flush with the screen top, so anything offset
        // above it is clipped by the window, and on notched Macs the shape
        // visibly retracts INTO the housing. The animation rides the
        // transaction of the controller's withAnimation around the
        // `revealed` mutation. ProbingOffset is `.offset` plus a frame
        // counter — the controller logs frames-per-transition so "did the
        // spring run" is answerable from the logs (a standalone spike
        // verified the mechanism at ~73 frames per transition; 1 = jumped).
        // Reduce Motion swaps the slide for a fade.
        .modifier(ProbingOffset(y: reduceMotion || context.revealed ? 0 : -(islandHeight + 32)))
        .opacity(reduceMotion && !context.revealed ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .onChange(of: mode) { _, new in
            if new != .hidden { displayMode = new }
        }
    }

    /// Extra shape height hidden above the screen edge on the attached
    /// (flush-top) modes. The reveal spring overshoots downward by a few
    /// points before settling; without this bleed the island's top briefly
    /// detaches from the screen edge — jarring, especially on plain
    /// monitors where there's no black housing to mask it. The bleed sits
    /// in the window's clipped region at rest, so it costs nothing visually.
    private static let topBleed: CGFloat = 28

    @ViewBuilder
    private func island(for mode: Mode, geo: NotchGeometry) -> some View {
        // The long-lived coach strip is the only state that must not cover
        // the menu bar on plain screens; everything else merges with the top
        // edge (and the notch where there is one). The detached pill needs
        // no bleed — it's free-floating, so overshoot just moves it.
        let detached = !geo.hasNotch && isCoach(mode)
        let topClearance = detached ? 0 : geo.topInset
        let bleed = detached ? 0 : Self.topBleed

        content(for: mode)
            .frame(width: width(for: mode, geo: geo))
            .padding(.top, topClearance + bleed)    // content clears notch / menu bar / bleed
            .background(
                IslandShape(detached: detached)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
            .offset(y: -bleed)                      // park the bleed above the screen edge
            .padding(.top, detached ? geo.topInset + 6 : 0)   // drop the pill below the menu bar
    }

    @ViewBuilder
    private func content(for mode: Mode) -> some View {
        switch mode {
        case .hidden:
            EmptyView()
        case .dictation:
            // Taller while the interim-preview well is reserved (recording
            // with the setting on); the one height morph happens at
            // recording start/end, never mid-recording.
            DictationIslandContent()
                .frame(height: dictationHeight)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dictationHeight)
        case .coach:
            if let engine = state.activeCoachEngine {
                CoachIslandContent(engine: engine)
            }
        }
    }

    private func isCoach(_ mode: Mode) -> Bool {
        if case .coach = mode { return true }
        return false
    }

    private var dictationHeight: CGFloat {
        if case .recording = state.pipeline.state,
           state.settings.realtimeInterimEnabled {
            return 134
        }
        return 96
    }

    private func width(for mode: Mode, geo: NotchGeometry) -> CGFloat {
        switch mode {
        case .hidden: 0
        case .dictation: 520
        // Ambient hugs the notch (plus a visible lip either side so the
        // strip registers at all); the nudge line needs room to read.
        case .coach(nudging: false): max(geo.notchWidth + 56, 210)
        case .coach(nudging: true): max(geo.notchWidth + 56, 380)
        }
    }
}

/// `.offset` plus an animation-frame counter: `animatableData`'s setter runs
/// once per frame while a transition animates and exactly once on a jump,
/// so the drained count distinguishes "spring ran" from "value snapped".
/// Costs nothing measurable; the island only transitions a few times a
/// minute at most.
struct ProbingOffset: GeometryEffect {
    var y: CGFloat
    var animatableData: CGFloat {
        get { y }
        set { y = newValue; IslandAnimationProbe.shared.record() }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: y))
    }
}

final class IslandAnimationProbe: @unchecked Sendable {
    static let shared = IslandAnimationProbe()
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    /// Returns frames recorded since the last drain and resets.
    func drain() -> Int { lock.lock(); defer { count = 0; lock.unlock() }; return count }
}

/// Top-anchored island silhouette: square shoulders that meet the screen's
/// top edge (merging with the notch housing where there is one), rounded
/// bottom corners. `detached` renders the fully-rounded standalone pill used
/// below the menu bar on plain screens.
private struct IslandShape: Shape {
    let detached: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(18, rect.height / 2)
        if detached {
            return Path(roundedRect: rect, cornerRadius: radius)
        }
        return Path(
            roundedRect: rect,
            cornerRadii: RectangleCornerRadii(
                topLeading: 0, bottomLeading: radius,
                bottomTrailing: radius, topTrailing: 0
            )
        )
    }
}
