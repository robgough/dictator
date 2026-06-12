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
    /// dropped down into view. The controller sequences this around the
    /// panel's order-front/order-out so the spring is actually seen — a
    /// SwiftUI change committed while the window is ordered out animates
    /// nothing.
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

    /// Local mirror of `context.revealed` whose every change is wrapped in
    /// an explicit `withAnimation` (see onChange below). The implicit
    /// `.animation(value:)` form proved unreliable across show/hide cycles —
    /// the first reveal animated, subsequent ones applied instantly.
    /// `withAnimation` animates from the current presentation value
    /// unconditionally, which is the guarantee we actually need.
    @State private var dropped = false

    var body: some View {
        let geo = context.geometry

        ZStack(alignment: .top) {
            if let displayMode {
                island(for: displayMode, geo: geo)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: displayMode)
        // Emergence: slide up behind the screen's top edge when tucked —
        // the panel sits flush with the screen top, so anything offset
        // above it is clipped by the window, and on notched Macs the shape
        // visibly retracts INTO the housing. Reduce Motion swaps the slide
        // for a plain fade.
        .offset(y: reduceMotion || dropped ? 0 : -IslandPanel.canvasSize.height)
        .opacity(reduceMotion && !dropped ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .onChange(of: mode) { _, new in
            if new != .hidden { displayMode = new }
        }
        .onChange(of: context.revealed) { _, revealedNow in
            guard !reduceMotion else {
                withAnimation(.easeOut(duration: 0.18)) { dropped = revealedNow }
                return
            }
            // Reveal gets a touch of spring overshoot (the "pop"); retract
            // is a quick clean tuck — bounce on the way out reads as
            // hesitation.
            withAnimation(
                revealedNow
                    ? .spring(response: 0.45, dampingFraction: 0.72)
                    : .spring(response: 0.32, dampingFraction: 1.0)
            ) {
                dropped = revealedNow
            }
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
            DictationIslandContent()
                .frame(height: 96)
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
