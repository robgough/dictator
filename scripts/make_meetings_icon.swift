#!/usr/bin/env swift
// Renders the Dictator Meetings app icon at every size macOS asks for.
// Run from the repo root: `swift scripts/make_meetings_icon.swift`
//
// Same family as Dictator's icon (scripts/make_icon.swift) — pale gradient
// squircle, the same blue gradient — but the glyph is the SF Symbol the
// app already uses in its menu-bar item, `person.2.wave.2` (two people and
// a voice), rendered through the gradient. Same colour, different picture:
// enough to tell the two apps apart in the Dock without looking like a
// different product family.
// Also writes docs/media/dictator-meetings-icon.png (512 px) for the site.

import AppKit
import CoreGraphics
import Foundation

private struct Variant {
    let scale: Int
    let point: Int
    var pixels: Int { scale * point }
    var filename: String { "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png" }
}

private let variants: [Variant] = [
    Variant(scale: 1, point: 16), Variant(scale: 2, point: 16),
    Variant(scale: 1, point: 32), Variant(scale: 2, point: 32),
    Variant(scale: 1, point: 128), Variant(scale: 2, point: 128),
    Variant(scale: 1, point: 256), Variant(scale: 2, point: 256),
    Variant(scale: 1, point: 512), Variant(scale: 2, point: 512),
]

private func renderIcon(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let corner = bgRect.width * 0.225
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Background: identical to Dictator's (paper white → cool light grey).
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGradient = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.985, green: 0.987, blue: 0.995, alpha: 1).cgColor,
        NSColor(srgbRed: 0.905, green: 0.920, blue: 0.945, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.05).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // Glyph: the menu-bar symbol, drawn through Dictator's blue gradient.
    // The symbol is rasterised large, then fitted to ~66% of the icon width
    // and centred; a transparency layer + destination-in keeps the gradient
    // only where the glyph has coverage, and the layer takes the shadow as
    // one shape.
    let symbolPoint = max(64, s * 0.55)
    let config = NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(config),
          let glyph = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("SF Symbol person.2.wave.2 unavailable")
    }
    let targetW = s * 0.66
    let scale = targetW / CGFloat(glyph.width)
    let glyphW = CGFloat(glyph.width) * scale
    let glyphH = CGFloat(glyph.height) * scale
    // Optically centred: the symbol's waves sit high, so nudge down a touch.
    let glyphRect = CGRect(x: (s - glyphW) / 2, y: (s - glyphH) / 2 - s * 0.01, width: glyphW, height: glyphH)

    let barGradient = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.32, green: 0.55, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.04, green: 0.40, blue: 0.92, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!

    // Turn the glyph's alpha into a Quartz image mask (0 = paint, 255 = keep
    // out) and clip the gradient through it. Compositing the gradient with
    // destination-in instead left a one-level tint across the whole glyph
    // rectangle from premultiplied rounding — invisible on disk, visible in
    // Finder's preview.
    let gw = glyph.width, gh = glyph.height
    var rgba = [UInt8](repeating: 0, count: gw * gh * 4)
    rgba.withUnsafeMutableBytes { buf in
        let tmp = CGContext(data: buf.baseAddress, width: gw, height: gh, bitsPerComponent: 8,
                            bytesPerRow: gw * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        tmp.draw(glyph, in: CGRect(x: 0, y: 0, width: gw, height: gh))
    }
    var maskBytes = [UInt8](repeating: 255, count: gw * gh)
    for i in 0..<(gw * gh) { maskBytes[i] = 255 &- rgba[i * 4 + 3] }
    let provider = CGDataProvider(data: Data(maskBytes) as CFData)!
    let mask = CGImage(maskWidth: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: gw, provider: provider, decode: nil, shouldInterpolate: true)!

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.025,
                  color: NSColor(srgbRed: 0.05, green: 0.15, blue: 0.45, alpha: 0.18).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.clip(to: glyphRect, mask: mask)
    ctx.drawLinearGradient(barGradient,
                           start: CGPoint(x: 0, y: glyphRect.maxY),
                           end: CGPoint(x: 0, y: glyphRect.minY), options: [])
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    return ctx.makeImage()!
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write PNG"])
    }
}

private func contentsJSON(for variants: [Variant]) -> String {
    let entries = variants.map { v -> String in
        """
            {
              "idiom" : "mac",
              "scale" : "\(v.scale)x",
              "size" : "\(v.point)x\(v.point)",
              "filename" : "\(v.filename)"
            }
        """
    }.joined(separator: ",\n")
    return """
    {
      "images" : [
    \(entries)
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = repoRoot.appendingPathComponent("Sources/DictatorMeetings/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for v in variants {
    let img = renderIcon(pixels: v.pixels)
    try writePNG(img, to: iconset.appendingPathComponent(v.filename))
    print("wrote \(v.filename) (\(v.pixels)px)")
}
try contentsJSON(for: variants).write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")

let site = repoRoot.appendingPathComponent("docs/media/dictator-meetings-icon.png")
try writePNG(renderIcon(pixels: 512), to: site)
print("wrote docs/media/dictator-meetings-icon.png")
