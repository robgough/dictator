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
    let context: IslandContext

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

    var body: some View {
        let geo = context.geometry
        let mode = self.mode

        ZStack(alignment: .top) {
            if mode != .hidden {
                island(for: mode, geo: geo)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: mode)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func island(for mode: Mode, geo: NotchGeometry) -> some View {
        // The long-lived coach strip is the only state that must not cover
        // the menu bar on plain screens; everything else merges with the top
        // edge (and the notch where there is one).
        let detached = !geo.hasNotch && isCoach(mode)
        let topClearance = detached ? 0 : geo.topInset

        content(for: mode)
            .frame(width: width(for: mode, geo: geo))
            .padding(.top, topClearance)            // content clears notch / menu bar
            .background(
                IslandShape(detached: detached)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            )
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
