import SwiftUI

/// The HUD-style picker: four cards, each a miniature Mac screen with that
/// style's HUD drawn where it actually appears, click to choose. A picture
/// says "top-centre out of the notch" versus "small badge above the Dock"
/// far better than the labels do.
struct HUDStyleGallery: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            ForEach(HUDStyle.allCases) { style in
                HUDStyleCard(style: style, selected: state.settings.hudStyle == style) {
                    guard state.settings.hudStyle != style else { return }
                    state.settings.hudStyle = style
                    state.save()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct HUDStyleCard: View {
    let style: HUDStyle
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private static let imageRadius: CGFloat = 8
    /// Gap between the image and the selection ring (the ring's 2 pt stroke
    /// sits at the outer edge of this padding, leaving a 2 pt clear gap).
    private static let ringInset: CGFloat = 4

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // The image is identical whether or not it's selected — same
                // hairline, same size — so the four stay a like-for-like
                // comparison. Selection is a ring drawn OUTSIDE the image
                // with a small gap, in padding every card reserves, so
                // choosing one never shifts or covers any pixels of the
                // screenshot (a border inside the image made the notch look
                // like it changed size).
                HUDStylePreview(style: style)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Self.imageRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.imageRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.brandBlue)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(5)
                        }
                    }
                    .padding(Self.ringInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.imageRadius + Self.ringInset, style: .continuous)
                            .strokeBorder(Color.brandBlue, lineWidth: 2)
                            .opacity(selected ? 1 : 0)
                    )
                    .scaleEffect(hovering && !selected ? 1.02 : 1)
                    .accessibilityHidden(true)
                Text(style.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A 16:10 "screen" — wallpaper, menu bar with a notch, an app window with a
/// few lines of text, the Dock — and the chosen HUD style drawn where the
/// real one sits. Everything is a fraction of the canvas size so the card
/// scales with the Settings window. Sizes are illustrative rather than to
/// scale (a true 1:10 mini badge would be a 3-point smudge); the
/// *relationships* are what matter: the islands hang from the top edge and
/// the small one is narrower, the pill and badge float just above the Dock
/// and the badge is the smallest of the four.
private struct HUDStylePreview: View {
    let style: HUDStyle

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let w = size.width
            let h = size.height

            // Wallpaper — fixed, so the four cards read the same in light and
            // dark appearance and the HUD colours mean the same thing.
            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.13, green: 0.28, blue: 0.60),
                        Color(red: 0.42, green: 0.25, blue: 0.60),
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: w, y: h)
                )
            )

            // Menu bar with an Apple-ish dot and a clock-ish pill.
            let menuBarH = 0.075 * h
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: menuBarH)), with: .color(.white.opacity(0.16)))
            ctx.fill(
                Path(ellipseIn: CGRect(x: 0.03 * w, y: menuBarH * 0.3, width: menuBarH * 0.4, height: menuBarH * 0.4)),
                with: .color(.white.opacity(0.7))
            )
            ctx.fill(
                Path(roundedRect: CGRect(x: 0.86 * w, y: menuBarH * 0.32, width: 0.10 * w, height: menuBarH * 0.36), cornerRadius: 1),
                with: .color(.white.opacity(0.6))
            )

            // Notch.
            let notchW = 0.16 * w
            ctx.fill(
                Path(
                    roundedRect: CGRect(x: (w - notchW) / 2, y: 0, width: notchW, height: menuBarH),
                    cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: 0.025 * w, bottomTrailing: 0.025 * w, topTrailing: 0)
                ),
                with: .color(.black)
            )

            // App window: title strip plus a few lines of "text".
            let win = CGRect(x: 0.10 * w, y: 0.17 * h, width: 0.80 * w, height: 0.68 * h)
            let winRadius = 0.025 * w
            ctx.fill(Path(roundedRect: win, cornerRadius: winRadius), with: .color(.white.opacity(0.14)))
            ctx.fill(
                Path(
                    roundedRect: CGRect(x: win.minX, y: win.minY, width: win.width, height: 0.07 * h),
                    cornerRadii: RectangleCornerRadii(topLeading: winRadius, bottomLeading: 0, bottomTrailing: 0, topTrailing: winRadius)
                ),
                with: .color(.white.opacity(0.10))
            )
            let lineWidths: [CGFloat] = [0.52, 0.66, 0.44, 0.58]
            for (i, fraction) in lineWidths.enumerated() {
                let y = win.minY + 0.12 * h + CGFloat(i) * 0.09 * h
                ctx.fill(
                    Path(roundedRect: CGRect(x: win.minX + 0.05 * w, y: y, width: fraction * win.width, height: 0.028 * h), cornerRadius: 1),
                    with: .color(.white.opacity(0.22))
                )
            }

            // Dock.
            let dockH = 0.065 * h
            let dockW = 0.34 * w
            let dockTop = h - 0.03 * h - dockH
            ctx.fill(
                Path(roundedRect: CGRect(x: (w - dockW) / 2, y: dockTop, width: dockW, height: dockH), cornerRadius: dockH / 2),
                with: .color(.white.opacity(0.22))
            )

            // The HUD itself.
            switch style {
            case .island:
                Self.drawIsland(&ctx, w: w, h: h, width: 0.42 * w, height: 0.20 * h, menuBarH: menuBarH, bars: 6)
            case .islandSmall:
                Self.drawIsland(&ctx, w: w, h: h, width: 0.30 * w, height: 0.15 * h, menuBarH: menuBarH, bars: 4)
            case .pill:
                Self.drawPill(&ctx, w: w, h: h, dockTop: dockTop)
            case .mini:
                Self.drawMini(&ctx, w: w, h: h, dockTop: dockTop)
            }
        }
    }

    // MARK: - HUD miniatures

    /// Black shape hanging from the top edge, square shoulders merging with
    /// the notch, content in the band below the menu bar: dot, bars, chip.
    private static func drawIsland(_ ctx: inout GraphicsContext, w: CGFloat, h: CGFloat, width: CGFloat, height: CGFloat, menuBarH: CGFloat, bars: Int) {
        let rect = CGRect(x: (w - width) / 2, y: 0, width: width, height: height)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 0.02 * w, y: 0.01 * h))
            layer.fill(
                Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: 0, bottomLeading: 0.035 * w, bottomTrailing: 0.035 * w, topTrailing: 0)),
                with: .color(.black)
            )
        }
        let midY = (menuBarH + height) / 2
        let inset = 0.05 * width
        let chipW = 0.22 * width
        drawRow(&ctx, in: CGRect(x: rect.minX + inset, y: midY, width: width - 2 * inset, height: 0), w: w, h: h, bars: bars, chipWidth: chipW, chipOpacity: 0.55)
    }

    /// Frosted near-capsule floating above the Dock: dot, bars, chip.
    private static func drawPill(_ ctx: inout GraphicsContext, w: CGFloat, h: CGFloat, dockTop: CGFloat) {
        let width = 0.30 * w
        let height = 0.09 * h
        let rect = CGRect(x: (w - width) / 2, y: dockTop - 0.05 * h - height, width: width, height: height)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 0.02 * w, y: 0.012 * h))
            layer.fill(Path(roundedRect: rect, cornerRadius: height * 0.4), with: .color(.white.opacity(0.94)))
        }
        let inset = 0.08 * width
        drawRow(&ctx, in: CGRect(x: rect.minX + inset, y: rect.midY, width: width - 2 * inset, height: 0), w: w, h: h, bars: 6, chipWidth: 0.22 * width, chipOpacity: 0.28)
    }

    /// Tiny dark capsule above the Dock: dot, bars, and the mode name as a
    /// short blue stroke.
    private static func drawMini(_ ctx: inout GraphicsContext, w: CGFloat, h: CGFloat, dockTop: CGFloat) {
        let width = 0.19 * w
        let height = 0.065 * h
        let rect = CGRect(x: (w - width) / 2, y: dockTop - 0.045 * h - height, width: width, height: height)
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 0.015 * w, y: 0.01 * h))
            layer.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(.black.opacity(0.92)))
        }
        let inset = 0.09 * width
        drawRow(&ctx, in: CGRect(x: rect.minX + inset, y: rect.midY, width: width - 2 * inset, height: 0), w: w, h: h, bars: 4, chipWidth: 0.26 * width, chipOpacity: 0.9)
    }

    /// The listening row every style shares — recording dot on the left, a
    /// run of meter bars, a mode chip on the right — laid out along the
    /// centre line `band.midY` across `band.width`. `bars` is the minimum
    /// number of bars; wider rows get more at the same pitch.
    private static func drawRow(_ ctx: inout GraphicsContext, in band: CGRect, w: CGFloat, h: CGFloat, bars: Int, chipWidth: CGFloat, chipOpacity: Double) {
        let blue = Color.brandBlue
        let dot = 0.022 * w
        ctx.fill(
            Path(ellipseIn: CGRect(x: band.minX, y: band.midY - dot / 2, width: dot, height: dot)),
            with: .color(blue)
        )
        let chipH = 0.032 * h
        ctx.fill(
            Path(roundedRect: CGRect(x: band.maxX - chipWidth, y: band.midY - chipH / 2, width: chipWidth, height: chipH), cornerRadius: chipH / 2),
            with: .color(blue.opacity(chipOpacity))
        )
        // Bars at a fixed pitch (like the real meter), as many as fit in the
        // gap between dot and chip, centred in it — stretching a handful of
        // bars across a wide island read as a picket fence.
        let gapL = band.minX + dot + 0.02 * w
        let gapR = band.maxX - chipWidth - 0.02 * w
        let available = max(0, gapR - gapL)
        let heights: [CGFloat] = [0.45, 0.8, 1.0, 0.6, 0.85, 0.5, 0.7, 0.4, 0.9, 0.55]
        let barW = 0.012 * w
        let pitch = barW * 2.0
        let count = max(bars, Int((available + (pitch - barW)) / pitch))
        let runWidth = CGFloat(count) * pitch - (pitch - barW)
        let startX = gapL + (available - runWidth) / 2
        let maxH = 0.05 * h
        for i in 0..<count {
            let bh = max(barW, heights[i % heights.count] * maxH)
            let x = startX + CGFloat(i) * pitch
            ctx.fill(
                Path(roundedRect: CGRect(x: x, y: band.midY - bh / 2, width: barW, height: bh), cornerRadius: barW / 2),
                with: .color(blue)
            )
        }
    }
}
