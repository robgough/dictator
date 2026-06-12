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
    /// Coach checklist expanded on the island (click to open). The
    /// controller watches this to grant the panel key-window status while
    /// the quick-add field needs typing, and collapses it when dictation
    /// takes the surface or the meeting ends.
    var coachExpanded = false
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
        case coach(nudging: Bool, expanded: Bool)
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
            return .coach(nudging: engine.activeNudge != nil, expanded: context.coachExpanded)
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
        // `revealed` mutation. Reduce Motion swaps the slide for a fade.
        .offset(y: reduceMotion || context.revealed ? 0 : -(islandHeight + 32))
        .opacity(reduceMotion && !context.revealed ? 0 : 1)
        .environment(\.colorScheme, .dark)
        .onChange(of: mode) { _, new in
            if new != .hidden { displayMode = new }
        }
    }

    /// Extra shape height hidden above the screen edge. The reveal spring
    /// overshoots downward by a few points before settling; without this
    /// bleed the island's top briefly detaches from the screen edge —
    /// jarring, especially on plain monitors where there's no black housing
    /// to mask it. The bleed sits in the window's clipped region at rest,
    /// so it costs nothing visually.
    private static let topBleed: CGFloat = 28

    @ViewBuilder
    private func island(for mode: Mode, geo: NotchGeometry) -> some View {
        // Every mode docks flush with the top edge — the coach strip
        // included. (An earlier cut floated the coach as a detached pill
        // below the menu bar on plain monitors; in use it read as a
        // disconnected blob rather than the same island, so the coach now
        // gets the identical faux-notch treatment and simply covers the
        // empty centre of the menu bar for the meeting's duration.)
        content(for: mode)
            .frame(width: width(for: mode, geo: geo))
            .padding(.top, geo.topInset + Self.topBleed)   // clear notch / menu bar / bleed
            .background(
                IslandShape()
                    .fill(.black)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
            .offset(y: -Self.topBleed)                     // park the bleed above the screen edge
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
        // Expanded checklist needs working room; the nudge line needs room
        // to read; the ambient strip hugs the notch (plus a visible lip
        // either side so it registers at all).
        case .coach(_, expanded: true): max(geo.notchWidth + 56, 440)
        case .coach(nudging: true, _): max(geo.notchWidth + 56, 380)
        case .coach: max(geo.notchWidth + 56, 210)
        }
    }
}

/// Top-anchored island silhouette: square shoulders that meet the screen's
/// top edge (merging with the notch housing where there is one), rounded
/// bottom corners.
private struct IslandShape: Shape {
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
