#!/usr/bin/env swift
// Renders the Dictator Meetings app icon at every size macOS asks for.
// Run from the repo root: `swift scripts/make_meetings_icon.swift`
//
// Same family as Dictator's icon (scripts/make_icon.swift): pale gradient
// squircle, centred 9-bar waveform of vertical capsules. Two things set it
// apart so the Dock, the switcher and the Applications folder read the two
// apps at a glance:
//   - colour: teal → sea-green instead of Dictator's blue;
//   - silhouette: a twin-peak envelope — two voices in a conversation —
//     instead of Dictator's single centred peak.
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

    // Background: the same paper-white → cool grey as Dictator, with the
    // faintest teal cast at the bottom so the two icons share a family but
    // not a swatch.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGradient = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.985, green: 0.992, blue: 0.990, alpha: 1).cgColor,
        NSColor(srgbRed: 0.895, green: 0.935, blue: 0.930, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.05).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // Twin-peak envelope: two speakers. Dictator's is a single centred peak.
    let heights: [CGFloat] = [0.30, 0.60, 0.86, 0.62, 0.36, 0.64, 0.84, 0.58, 0.30]
    let barCount = CGFloat(heights.count)
    let clusterWidth = s * 0.62
    let clusterX = (s - clusterWidth) / 2
    let gapRatio: CGFloat = 0.55
    let barW = clusterWidth / (barCount + (barCount - 1) * gapRatio)
    let gap = barW * gapRatio
    let maxBarH = s * 0.70

    // Teal → sea-green. Deliberately far from Dictator's blue on the hue
    // wheel, and from the system green, so it reads as its own thing.
    let barGradient = CGGradient(colorsSpace: cs, colors: [
        NSColor(srgbRed: 0.30, green: 0.82, blue: 0.74, alpha: 1).cgColor,
        NSColor(srgbRed: 0.02, green: 0.56, blue: 0.50, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.025,
                  color: NSColor(srgbRed: 0.02, green: 0.30, blue: 0.28, alpha: 0.20).cgColor)
    let cluster = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = clusterX + CGFloat(i) * (barW + gap)
        let barH = maxBarH * h
        let y = (s - barH) / 2
        let rect = CGRect(x: x, y: y, width: barW, height: barH)
        let r = barW / 2
        cluster.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    }
    ctx.addPath(cluster)
    ctx.clip()
    ctx.drawLinearGradient(barGradient,
                           start: CGPoint(x: 0, y: (s + maxBarH) / 2),
                           end: CGPoint(x: 0, y: (s - maxBarH) / 2), options: [])
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
