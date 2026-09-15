import SwiftUI

/// The little illustrated Mac screen that Settings draws things on top of —
/// wallpaper, menu bar with a notch, an app window with a few lines of text,
/// and the Dock.
///
/// Extracted from `HUDStyleGallery`, which invented it, so the Scratchpad's
/// size preview can sit on exactly the same surface rather than on a grey
/// rectangle that looks like a different idea. Everything is a fraction of
/// the canvas, so one drawing serves any size or aspect ratio.
enum MiniDesktop {

    /// Landmarks the caller needs to place something on the drawing.
    struct Metrics {
        let menuBarHeight: CGFloat
        /// Top edge of the Dock, for anything that floats just above it.
        let dockTop: CGFloat
    }

    /// Draw the desktop and return its landmarks.
    @discardableResult
    static func draw(_ ctx: inout GraphicsContext, size: CGSize) -> Metrics {
        let w = size.width
        let h = size.height

        // Wallpaper — fixed, so the drawing reads the same in light and dark
        // appearance and the colours on top of it mean the same thing.
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

        return Metrics(menuBarHeight: menuBarH, dockTop: dockTop)
    }
}
