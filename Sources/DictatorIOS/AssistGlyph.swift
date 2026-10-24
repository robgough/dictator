import SwiftUI

/// Dictator's Assist mark: a burst with two sparkles, drawn from a single
/// 24×24 path. A `Shape` rather than an image asset so the app and the
/// keyboard extension (which has no asset catalog) share one definition,
/// and it fills with whatever foreground style it's given, like a
/// template image.
struct AssistGlyph: Shape {
    /// Stands in for an SF Symbol name wherever a control takes its icon as
    /// a string; `RecordGlyph` draws this shape for it.
    static let name = "dictator.assist"

    func path(in rect: CGRect) -> Path {
        var p = Path()
        // The burst: a wand with a rounded handle end.
        p.move(to: CGPoint(x: 3, y: 18))
        p.addLine(to: CGPoint(x: 14, y: 8.3))
        p.addLine(to: CGPoint(x: 11.6, y: 3.6))
        p.addLine(to: CGPoint(x: 16, y: 6.3))
        p.addLine(to: CGPoint(x: 20.4, y: 3.6))
        p.addLine(to: CGPoint(x: 18, y: 8.3))
        p.addLine(to: CGPoint(x: 20.4, y: 12.4))
        p.addLine(to: CGPoint(x: 16, y: 10.3))
        p.addLine(to: CGPoint(x: 6, y: 21))
        // SVG `A2.1 2.1 0 0 1 3 18`: the endpoints are slightly further
        // apart than the diameter, so SVG scales the radius up to a half
        // circle centred between them, swept clockwise on screen.
        p.addRelativeArc(center: CGPoint(x: 4.5, y: 19.5), radius: 4.5.squareRoot(),
                         startAngle: .degrees(45), delta: .degrees(180))
        p.closeSubpath()

        sparkle(&p, top: CGPoint(x: 6.2, y: 2.2), right: CGPoint(x: 9.6, y: 5.6),
                bottom: CGPoint(x: 6.2, y: 9), left: CGPoint(x: 2.8, y: 5.6),
                pinch: CGSize(width: 0.5, height: 0.5))
        sparkle(&p, top: CGPoint(x: 21.2, y: 14.2), right: CGPoint(x: 23.8, y: 16.8),
                bottom: CGPoint(x: 21.2, y: 19.4), left: CGPoint(x: 18.6, y: 16.8),
                pinch: CGSize(width: 0.4, height: 0.4))

        let scale = min(rect.width, rect.height) / 24
        let dx = rect.minX + (rect.width - 24 * scale) / 2
        let dy = rect.minY + (rect.height - 24 * scale) / 2
        return p.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }

    /// A four-pointed sparkle of quadratic curves, each control point
    /// `pinch` in from the centre lines (matches the source path).
    private func sparkle(_ p: inout Path, top: CGPoint, right: CGPoint, bottom: CGPoint, left: CGPoint, pinch: CGSize) {
        let cx = top.x, cy = right.y
        p.move(to: top)
        p.addQuadCurve(to: right, control: CGPoint(x: cx + pinch.width, y: cy - pinch.height))
        p.addQuadCurve(to: bottom, control: CGPoint(x: cx + pinch.width, y: cy + pinch.height))
        p.addQuadCurve(to: left, control: CGPoint(x: cx - pinch.width, y: cy + pinch.height))
        p.addQuadCurve(to: top, control: CGPoint(x: cx - pinch.width, y: cy - pinch.height))
        p.closeSubpath()
    }
}

/// An icon given by name: an SF Symbol, or the Assist glyph for
/// `AssistGlyph.name`. `size` is the symbol's point size; the glyph is drawn
/// a little larger so it sits at the same visual weight as a symbol.
struct RecordGlyph: View {
    let name: String
    var size: CGFloat
    var weight: Font.Weight = .semibold

    var body: some View {
        if name == AssistGlyph.name {
            AssistGlyph()
                .frame(width: size * 1.15, height: size * 1.15)
                .accessibilityHidden(true)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
        }
    }
}
