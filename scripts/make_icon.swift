#!/usr/bin/env swift
// Renders the Dictator app icon at every size macOS asks for.
// Run from the repo root: `swift scripts/make_icon.swift`
//
// Design: pale gradient squircle with a centred 9-bar voice waveform in the
// system-blue accent. Each bar is a vertical capsule; tall and short bars
// share a single vertical gradient so the cluster reads as one shape.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output spec

private struct Variant {
    let scale: Int          // 1 or 2
    let point: Int          // 16, 32, 128, 256, 512
    var pixels: Int { scale * point }
    var filename: String { "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png" }
}

private let variants: [Variant] = [
    Variant(scale: 1, point: 16),
    Variant(scale: 2, point: 16),
    Variant(scale: 1, point: 32),
    Variant(scale: 2, point: 32),
    Variant(scale: 1, point: 128),
    Variant(scale: 2, point: 128),
    Variant(scale: 1, point: 256),
    Variant(scale: 2, point: 256),
    Variant(scale: 1, point: 512),
    Variant(scale: 2, point: 512),
]

// MARK: - Drawing

private func renderIcon(pixels: Int) -> CGImage {
    let s = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: info
    )!
    ctx.interpolationQuality = .high

    let bgRect = CGRect(x: 0, y: 0, width: s, height: s)
    let corner = bgRect.width * 0.225
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Background gradient: paper white -> cool light grey
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.985, green: 0.987, blue: 0.995, alpha: 1).cgColor,
            NSColor(srgbRed: 0.905, green: 0.920, blue: 0.945, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Subtle inner border for definition against pure-white Dock backgrounds.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.05).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // Waveform bars. Centred vertically; heights mimic a voice envelope.
    let heights: [CGFloat] = [0.30, 0.46, 0.66, 0.82, 0.58, 0.86, 0.64, 0.44, 0.28]
    let barCount = CGFloat(heights.count)
    let clusterWidth = s * 0.62
    let clusterX = (s - clusterWidth) / 2
    let gapRatio: CGFloat = 0.55
    let barW = clusterWidth / (barCount + (barCount - 1) * gapRatio)
    let gap = barW * gapRatio
    let maxBarH = s * 0.70

    let barGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.32, green: 0.55, blue: 1.00, alpha: 1).cgColor,
            NSColor(srgbRed: 0.04, green: 0.40, blue: 0.92, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.006),
        blur: s * 0.025,
        color: NSColor(srgbRed: 0.05, green: 0.15, blue: 0.45, alpha: 0.18).cgColor
    )

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
    ctx.drawLinearGradient(
        barGradient,
        start: CGPoint(x: 0, y: (s + maxBarH) / 2),
        end: CGPoint(x: 0, y: (s - maxBarH) / 2),
        options: []
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - PNG writer

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write PNG"])
    }
}

// MARK: - Contents.json

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

// MARK: - Main

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = repoRoot.appendingPathComponent("Sources/Dictator/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for v in variants {
    let img = renderIcon(pixels: v.pixels)
    let out = iconset.appendingPathComponent(v.filename)
    try writePNG(img, to: out)
    print("wrote \(v.filename) (\(v.pixels)px)")
}

let json = contentsJSON(for: variants)
try json.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
