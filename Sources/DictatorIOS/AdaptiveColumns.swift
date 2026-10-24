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
struct AdaptiveColumns<Main: View, Companion: View>: View {
    var companionRange: ClosedRange<CGFloat> = 320...380
    private let wantsCompanion: Bool
    private let main: (_ companionShown: Bool) -> Main
    private let companion: () -> Companion
    private let onCompanionChange: (Bool) -> Void

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
        GeometryReader { proxy in
            let plan = ColumnPlan.make(
                width: proxy.size.width,
                fold: FoldGeometry.verticalFold(in: proxy),
                wantsCompanion: wantsCompanion,
                companionRange: companionRange
            )
            HStack(spacing: 0) {
                if let width = plan.companionWidth {
                    companion()
                        .frame(width: width)
                        .overlay(alignment: .trailing) {
                            // A hairline where the columns meet; on a fold
                            // the gap does that job.
                            if plan.gap == 0 {
                                Rectangle()
                                    .fill(Color(.separator))
                                    .frame(width: 0.5)
                                    .ignoresSafeArea()
                            }
                        }
                        .padding(.trailing, plan.gap)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                // Always the same structural child, so its state (focus,
                // scroll, an open editor) survives the companion coming and
                // going.
                main(plan.showsCompanion)
                    .frame(width: plan.mainWidth)
                    .padding(.leading, plan.mainLeading)
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: plan)
            .onChange(of: plan.showsCompanion, initial: true) { _, shown in
                onCompanionChange(shown)
            }
        }
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
