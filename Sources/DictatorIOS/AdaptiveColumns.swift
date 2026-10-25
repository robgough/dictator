import SwiftUI

/// Width classes for the app's layouts, from the space the tab actually has —
/// never the device, the idiom, the orientation or the size class. A window
/// can be resized (iPad split view, Slide Over, Stage Manager) or unfolded
/// (iPhone Duo), and only its width tracks all of those live.
///
/// - narrow: under 500pt. iPhone, the closed Duo, Slide Over, a ⅓ iPad split.
/// - medium: 500–840pt. A ½ or ⅔ split, an 11-inch iPad in portrait.
///   Still one column, held to a readable width.
/// - wide: 840pt and up. The open Duo (867pt beside its system strip), iPad
///   full screen. Room for a companion column beside the main content.
enum ColumnWidthClass: Equatable {
    case narrow, medium, wide

    static let mediumMinimum: CGFloat = 500
    static let wideMinimum: CGFloat = 840

    init(width: CGFloat) {
        if width >= Self.wideMinimum {
            self = .wide
        } else if width >= Self.mediumMinimum {
            self = .medium
        } else {
            self = .narrow
        }
    }
}

/// Where each column goes, worked out from the width and any fold.
struct ColumnPlan: Equatable {
    /// The companion's width, or nil when it isn't shown.
    var companionWidth: CGFloat?
    /// Empty space between the companion and the main content (the fold).
    var gap: CGFloat = 0
    /// Empty space before the main content when there's no companion
    /// (the fold, when the main content has to sit past it).
    var mainLeading: CGFloat = 0
    var mainWidth: CGFloat

    var showsCompanion: Bool { companionWidth != nil }

    /// - Parameters:
    ///   - width: the container's width.
    ///   - fold: the horizontal span of an active vertical fold, in the
    ///     container's coordinates, margins included. Nil when the device is
    ///     flat or has no fold — a flat crease is invisible, so it is not an
    ///     edge to lay out around.
    ///   - wantsCompanion: whether this screen has a companion column at all.
    ///   - companionRange: the companion's allowed width.
    static func make(
        width: CGFloat,
        fold: ClosedRange<CGFloat>?,
        wantsCompanion: Bool,
        companionRange: ClosedRange<CGFloat>
    ) -> ColumnPlan {
        if let fold, fold.lowerBound > 0, fold.upperBound < width {
            // Partly folded: nothing sits on the crease. Main content takes
            // the trailing side, the companion the leading side, when each
            // has room; otherwise the main content takes the bigger side
            // alone.
            let leading = fold.lowerBound
            let trailing = width - fold.upperBound
            let minimumMain: CGFloat = 320
            if wantsCompanion, leading >= companionRange.lowerBound - 40, trailing >= minimumMain {
                return ColumnPlan(
                    companionWidth: leading,
                    gap: fold.upperBound - fold.lowerBound,
                    mainWidth: trailing
                )
            }
            if trailing >= leading {
                return ColumnPlan(mainLeading: fold.upperBound, mainWidth: trailing)
            }
            return ColumnPlan(mainWidth: leading)
        }
        guard wantsCompanion, ColumnWidthClass(width: width) == .wide else {
            return ColumnPlan(mainWidth: width)
        }
        let companion = min(max(width * 0.3, companionRange.lowerBound), companionRange.upperBound)
        return ColumnPlan(companionWidth: companion, mainWidth: width - companion)
    }
}

/// One adaptive container for every tab: the main content on the trailing
/// side taking most of the width, and on a wide window a narrower companion
/// column before it (between the system sidebar and the main content).
/// Narrower than that, only the main content shows and the companion is
/// reached however the screen reaches it on a phone (a sheet).
///
/// Give the companion no NavigationStack of its own: on the open Duo every
/// navigation stack holds back room for the system strip on the trailing
/// edge (84pt), even one that doesn't touch it, and the column loses a
/// quarter of its width.
///
/// On an iPhone Duo that's partly folded, the columns step around the fold
/// so no text or control sits on the crease. Flat, the crease is invisible
/// and ignored.
///
/// ## Changing layout smoothly
///
/// Unfolding the Duo or turning an iPad changes the width, and often whether
/// the companion shows. The transition is built to stay at display rate:
///
/// - The companion coming or going (an unfold, an iPad turning) happens as
///   the window itself resizes, so the columns are laid out at their
///   **final** widths straight away and only slide: the main column across,
///   the companion in (or out) from the leading edge beside it, fading.
/// - A fold arriving, moving as the hinge closes, or going flat happens in
///   a window that keeps its size, so the column edges move with it: the
///   fold opens between the columns and they narrow to make room, the way
///   an iPad split resizes, rather than jumping to their new widths.
/// - Every change rides the same spring, and a spring retargets with the
///   velocity it already has, so a hinge moving through several fold
///   positions in a row reads as one continuous movement.
/// - No GeometryReader. The width class and fold are read with
///   `onGeometryChange`, which only fires when they change, and each column
///   is evaluated in its own view, so a change one column reads doesn't
///   rebuild the other.
/// - The main column is always the same view, so its state (focus, scroll,
///   an open editor) survives the companion coming and going.
struct AdaptiveColumns<Main: View, Companion: View>: View {
    var companionRange: ClosedRange<CGFloat> = 320...380
    private let wantsCompanion: Bool
    private let main: (_ companionShown: Bool) -> Main
    private let companion: () -> Companion
    private let onCompanionChange: (Bool) -> Void

    /// What the window's width and fold decided, as last measured. Nil until
    /// the first measurement, which is applied without animation.
    @State private var measured: ColumnMeasurement?
    /// 0 with the companion hidden, 1 with it shown; animated between.
    @State private var reveal: CGFloat = 0
    /// 0 flat, 1 partly folded; animated between.
    @State private var folded: CGFloat = 0
    /// Where the fold is (or last was, while it animates away); animated
    /// as it moves.
    @State private var foldSpan = FoldSpan(lower: 0, upper: 0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - main: the main content, told whether the companion is showing so
    ///     it can drop the button that would otherwise open it.
    ///   - companion: the companion column's content.
    ///   - onCompanionChange: called when the companion appears or goes.
    init(
        companionRange: ClosedRange<CGFloat> = 320...380,
        onCompanionChange: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder main: @escaping (_ companionShown: Bool) -> Main,
        @ViewBuilder companion: @escaping () -> Companion
    ) {
        self.companionRange = companionRange
        self.wantsCompanion = true
        self.main = main
        self.companion = companion
        self.onCompanionChange = onCompanionChange
    }

    var body: some View {
        let shown = measured?.showsCompanion ?? false
        let wantsCompanion = wantsCompanion
        let companionRange = companionRange
        ColumnsLayout(
            fold: measured?.fold,
            wantsCompanion: wantsCompanion,
            companionRange: companionRange,
            reveal: reveal,
            folded: folded,
            foldSpan: foldSpan
        ) {
            if shown {
                ColumnContent { companion() }
                    .overlay(alignment: .trailing) {
                        // A hairline where the columns meet; on a fold
                        // the gap does that job, so it fades as one opens.
                        Rectangle()
                            .fill(Color(.separator))
                            .frame(width: 0.5)
                            .ignoresSafeArea()
                            .opacity(1 - folded)
                    }
                    .layoutValue(key: ColumnRoleKey.self, value: .companion)
                    // The layout slides it; the transition only fades it.
                    .transition(.opacity)
            }
            // Always the same structural child, so its state survives the
            // companion coming and going.
            ColumnContent { main(shown) }
                .layoutValue(key: ColumnRoleKey.self, value: .main)
        }
        // Shows in the sliver the main column hasn't reached yet as it
        // slides across at its final width.
        .background(Color(.systemBackground).ignoresSafeArea())
        .onGeometryChange(for: ColumnMeasurement.self) { proxy in
            let fold = FoldGeometry.verticalFold(in: proxy)
            let plan = ColumnPlan.make(
                width: proxy.size.width,
                fold: fold,
                wantsCompanion: wantsCompanion,
                companionRange: companionRange
            )
            return ColumnMeasurement(showsCompanion: plan.showsCompanion, fold: fold, gap: plan.gap)
        } action: { next in
            apply(next)
        }
    }

    private func apply(_ next: ColumnMeasurement) {
        let previous = measured
        let changed = previous?.showsCompanion != next.showsCompanion
        // Every change animates, not only the companion coming and going: a
        // fold arriving, moving or going flat would otherwise jump the
        // columns. A first layout starts where it is, with no slide on launch.
        withAnimation(previous == nil ? nil : motion) {
            measured = next
            reveal = next.showsCompanion ? 1 : 0
            folded = next.fold == nil ? 0 : 1
            // A fold going flat keeps its last span, so the columns slide
            // away from where it was rather than from the leading edge.
            if let fold = next.fold {
                foldSpan = FoldSpan(lower: fold.lowerBound, upper: fold.upperBound)
            }
        }
        if changed { onCompanionChange(next.showsCompanion) }
    }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.88)
    }
}

extension AdaptiveColumns where Companion == EmptyView {
    /// A single column that still steps around a partly folded Duo's crease.
    init(@ViewBuilder main: @escaping () -> Main) {
        self.wantsCompanion = false
        self.main = { _ in main() }
        self.companion = { EmptyView() }
        self.onCompanionChange = { _ in }
    }
}

/// Evaluates a column's content in its own body, so the observable state a
/// column reads invalidates that column alone, not the container and every
/// column in it.
private struct ColumnContent<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

/// What a window's width and fold decided for `AdaptiveColumns`.
private struct ColumnMeasurement: Equatable {
    var showsCompanion: Bool
    var fold: ClosedRange<CGFloat>?
    var gap: CGFloat
}

private enum ColumnRole {
    case main, companion
}

private struct ColumnRoleKey: LayoutValueKey {
    static let defaultValue: ColumnRole = .main
}

/// A fold's horizontal span, animatable.
private struct FoldSpan: Equatable {
    var lower: CGFloat
    var upper: CGFloat

    var range: ClosedRange<CGFloat> { lower...max(lower, upper) }
}

/// Places the columns, from two animated inputs:
///
/// - `reveal` slides the main column between its companion-hidden and
///   companion-shown positions at its final width, and the companion rides
///   along just before it, so it slides in from (or out to) the leading edge.
/// - `folded` and `foldSpan` blend every frame (widths too) between the flat
///   plan and the plan around the fold, so the fold opening, moving or
///   closing moves the column edges continuously.
private struct ColumnsLayout: Layout {
    var fold: ClosedRange<CGFloat>?
    var wantsCompanion: Bool
    var companionRange: ClosedRange<CGFloat>
    var reveal: CGFloat
    var folded: CGFloat
    var foldSpan: FoldSpan

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(reveal, folded), AnimatablePair(foldSpan.lower, foldSpan.upper)) }
        set {
            reveal = newValue.first.first
            folded = newValue.first.second
            foldSpan = FoldSpan(lower: newValue.second.first, upper: newValue.second.second)
        }
    }

    /// The companion's last width, kept so a companion that's leaving (the
    /// window has already narrowed, or the fold has gone) can slide out at
    /// the size it had.
    struct Cache {
        var companionWidth: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// Keep the cache when the subviews change. The default rebuilds it,
    /// which would forget the leaving companion's width the moment it
    /// started leaving, and snap everything to the end of the slide.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    /// Where the columns go under one plan, given the companion's width.
    private struct Frames {
        var companionWidth: CGFloat
        var gap: CGFloat
        var mainLeading: CGFloat
        var mainWidth: CGFloat

        func blended(to other: Frames, by amount: CGFloat) -> Frames {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
            return Frames(
                companionWidth: mix(companionWidth, other.companionWidth),
                gap: mix(gap, other.gap),
                mainLeading: mix(mainLeading, other.mainLeading),
                mainWidth: mix(mainWidth, other.mainWidth)
            )
        }
    }

    private func frames(_ plan: ColumnPlan, companionWidth: CGFloat) -> Frames {
        Frames(
            companionWidth: plan.companionWidth ?? companionWidth,
            gap: plan.gap,
            mainLeading: plan.mainLeading,
            mainWidth: plan.mainWidth
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        // The plan for where things are going.
        let target = ColumnPlan.make(
            width: bounds.width,
            fold: fold,
            wantsCompanion: wantsCompanion,
            companionRange: companionRange
        )
        if let width = target.companionWidth {
            cache.companionWidth = width
        }
        // The flat plan and the plan around the (animated) fold, blended by
        // how folded the layout currently is: the fold opens between the
        // columns, and their edges move with it.
        let flat = frames(
            ColumnPlan.make(width: bounds.width, fold: nil, wantsCompanion: wantsCompanion, companionRange: companionRange),
            companionWidth: cache.companionWidth
        )
        let amount = min(max(folded, 0), 1)
        var place = flat
        if amount > 0 {
            let around = frames(
                ColumnPlan.make(
                    width: bounds.width,
                    fold: foldSpan.range,
                    wantsCompanion: wantsCompanion,
                    companionRange: companionRange
                ),
                companionWidth: cache.companionWidth
            )
            place = flat.blended(to: around, by: amount)
        }
        // The companion coming or going: the main column slides at its final
        // width (the window has just been resized anyway), the companion
        // riding along before it.
        let progress = min(max(reveal, 0), 1.2)
        let shownX = place.companionWidth + place.gap
        let mainX = place.mainLeading + (shownX - place.mainLeading) * progress
        let arriving = reveal > 0.001 && reveal < 0.999
        let mainWidth = arriving ? target.mainWidth : place.mainWidth

        for subview in subviews {
            switch subview[ColumnRoleKey.self] {
            case .main:
                subview.place(
                    at: CGPoint(x: bounds.minX + mainX, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: mainWidth, height: bounds.height)
                )
            case .companion:
                subview.place(
                    at: CGPoint(x: bounds.minX + mainX - place.gap - place.companionWidth, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: place.companionWidth, height: bounds.height)
                )
            }
        }
    }
}
