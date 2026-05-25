#!/usr/bin/env swift
// Icon design iteration round 2 — three bolder directions.
//
// Run from the repo root: `swift scripts/make_ios_icon_concepts.swift`
//
// All renders are 1024×1024 RGB (no alpha), full-bleed, ready to drop into
// the iOS app-icon slot if chosen. iOS clips the corners with its own
// rounded mask at display time.
//
// C1: Dark vibrant — deep navy → electric blue gradient, single bold
//     white waveform. Breaks from the Voice Memos pastel association.
// C2: Speech bubble — coloured ground with a chat-bubble silhouette in
//     light cream, waveform inside. The bubble tail is the differentiator.
// C3: Heavy-weight D letterform — real typography (SF Pro Display Black)
//     dominating the canvas, waveform sitting inside the bowl.

import AppKit
import CoreGraphics
import CoreText
import Foundation

private let pixels = 1024

private let cs = CGColorSpaceCreateDeviceRGB()

private func makeContext(_ s: CGFloat) -> CGContext {
    let ctx = CGContext(
        data: nil,
        width: Int(s),
        height: Int(s),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    ctx.interpolationQuality = .high
    return ctx
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2)
    }
}

// MARK: - C1: Dark vibrant + bold waveform

private func renderC1() -> CGImage {
    let s = CGFloat(pixels)
    let ctx = makeContext(s)

    // Deep navy → electric royal blue. Strong contrast, owns the canvas.
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.04, green: 0.06, blue: 0.16, alpha: 1).cgColor,
            NSColor(srgbRed: 0.18, green: 0.30, blue: 0.85, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: s),
        options: []
    )

    // Bold waveform — 5 chunky bars (not 9 skinny ones). White, with a
    // soft drop-glow to lift it off the dark ground.
    let heights: [CGFloat] = [0.42, 0.74, 0.96, 0.66, 0.38]
    let barCount = CGFloat(heights.count)
    let clusterWidth = s * 0.58
    let gapRatio: CGFloat = 0.45
    let barW = clusterWidth / (barCount + (barCount - 1) * gapRatio)
    let gap = barW * gapRatio
    let maxBarH = s * 0.62
    let clusterX = (s - clusterWidth) / 2

    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = clusterX + CGFloat(i) * (barW + gap)
        let barH = maxBarH * h
        let y = (s - barH) / 2
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: barW, height: barH),
                            cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.004),
        blur: s * 0.04,
        color: NSColor(srgbRed: 0.5, green: 0.7, blue: 1.0, alpha: 0.55).cgColor
    )
    ctx.addPath(bars)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - C2: Speech bubble silhouette

private func renderC2() -> CGImage {
    let s = CGFloat(pixels)
    let ctx = makeContext(s)

    // Dark warm-grey ground so the cream bubble pops.
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1).cgColor,
            NSColor(srgbRed: 0.06, green: 0.08, blue: 0.12, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Speech bubble: a rounded rect with a triangular tail dropping from
    // the bottom-left. Sized to fill most of the canvas, leaving headroom
    // for iOS to round the outer corners without clipping the bubble.
    let inset = s * 0.10
    let bubbleRect = CGRect(x: inset, y: inset + s * 0.04,
                            width: s - inset * 2, height: s - inset * 2 - s * 0.04)
    let bubbleCorner = s * 0.12

    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: bubbleRect, cornerWidth: bubbleCorner, cornerHeight: bubbleCorner)

    // Tail: a triangular protrusion off the bottom edge, set in from the
    // left corner. Coordinates: y increases upward in CG space.
    let tailLeftX = bubbleRect.minX + bubbleRect.width * 0.18
    let tailRightX = bubbleRect.minX + bubbleRect.width * 0.30
    let tailTipY = bubbleRect.minY - s * 0.07
    let tailTipX = bubbleRect.minX + bubbleRect.width * 0.13
    let tailBaseY = bubbleRect.minY + s * 0.01  // tiny overlap into bubble
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: tailLeftX, y: tailBaseY))
    tail.addLine(to: CGPoint(x: tailRightX, y: tailBaseY))
    tail.addLine(to: CGPoint(x: tailTipX, y: tailTipY))
    tail.closeSubpath()

    let bubbleShape = CGMutablePath()
    bubbleShape.addPath(bubble)
    bubbleShape.addPath(tail)

    // Cream / off-white fill so it reads as paper.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.008),
        blur: s * 0.04,
        color: NSColor.black.withAlphaComponent(0.45).cgColor
    )
    ctx.addPath(bubbleShape)
    let cream = NSColor(srgbRed: 0.985, green: 0.972, blue: 0.948, alpha: 1)
    ctx.setFillColor(cream.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Waveform inside the bubble — blue gradient, same family as the
    // existing brand bars but tuned to fit the available width.
    let blueGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.32, green: 0.55, blue: 1.00, alpha: 1).cgColor,
            NSColor(srgbRed: 0.04, green: 0.40, blue: 0.92, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!

    let heights: [CGFloat] = [0.40, 0.70, 0.92, 0.62, 0.36]
    let barCount = CGFloat(heights.count)
    let waveWidth = bubbleRect.width * 0.62
    let gapRatio: CGFloat = 0.50
    let barW = waveWidth / (barCount + (barCount - 1) * gapRatio)
    let gap = barW * gapRatio
    let maxBarH = bubbleRect.height * 0.62
    let waveX = bubbleRect.midX - waveWidth / 2

    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = waveX + CGFloat(i) * (barW + gap)
        let barH = maxBarH * h
        let y = bubbleRect.midY - barH / 2
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: barW, height: barH),
                            cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }

    ctx.saveGState()
    ctx.addPath(bars)
    ctx.clip()
    ctx.drawLinearGradient(
        blueGradient,
        start: CGPoint(x: 0, y: bubbleRect.midY + maxBarH / 2),
        end: CGPoint(x: 0, y: bubbleRect.midY - maxBarH / 2),
        options: []
    )
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - C3: Heavy-weight D letterform + waveform

private func renderC3() -> CGImage {
    let s = CGFloat(pixels)
    let ctx = makeContext(s)

    // Pale gradient ground (kept similar to the macOS icon family so the
    // app reads as part of the same lineage).
    let bgGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.985, green: 0.987, blue: 0.995, alpha: 1).cgColor,
            NSColor(srgbRed: 0.890, green: 0.910, blue: 0.940, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Real typography: SF Pro Display at black weight, large enough that
    // the D fills most of the canvas. Using CTFont rather than nsfont so
    // we have proper kerning + outline path.
    let descriptor = NSFontDescriptor(name: "SFProDisplay-Black", size: s * 0.88)
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.black.rawValue]])
    let font = CTFontCreateWithFontDescriptor(descriptor, s * 0.88, nil)
    let glyph: CGGlyph = {
        var unichar: UniChar = "D".utf16.first!
        var g: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &unichar, &g, 1)
        return g
    }()

    // Position the D centred. Get its bounding rect so we can centre
    // precisely on the canvas (font metrics include ascender/descender
    // padding that would otherwise offset the letter visually).
    var bbox = CGRect.zero
    var gly = glyph
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &gly, &bbox, 1)
    let dPath = CTFontCreatePathForGlyph(font, glyph, nil)!
    var translate = CGAffineTransform(
        translationX: (s - bbox.width) / 2 - bbox.minX,
        y: (s - bbox.height) / 2 - bbox.minY
    )
    let centredD = dPath.copy(using: &translate)!

    // Fill the D with a deep gradient — dark navy fading to a slightly
    // lighter slate so the form has dimension.
    let dGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            NSColor(srgbRed: 0.10, green: 0.14, blue: 0.30, alpha: 1).cgColor,
            NSColor(srgbRed: 0.04, green: 0.30, blue: 0.82, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.008),
        blur: s * 0.025,
        color: NSColor(srgbRed: 0.05, green: 0.15, blue: 0.45, alpha: 0.30).cgColor
    )
    ctx.addPath(centredD)
    ctx.clip()
    ctx.drawLinearGradient(
        dGradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // Waveform inside the D's bowl. Use the letter's bounding box as a
    // rough proxy for the bowl region — slightly inset on the right
    // (bowl side) to avoid clipping into the curved edge.
    let bowlLeftEdge = (s - bbox.width) / 2 - bbox.minX + bbox.width * 0.36
    let bowlRightEdge = (s + bbox.width) / 2 - bbox.minX - bbox.width * 0.18
    let bowlWidth = bowlRightEdge - bowlLeftEdge
    let bowlCenterY = s / 2
    let heights: [CGFloat] = [0.42, 0.72, 0.92, 0.62, 0.36]
    let barCount = CGFloat(heights.count)
    let gapRatio: CGFloat = 0.55
    let barW = bowlWidth / (barCount + (barCount - 1) * gapRatio)
    let gap = barW * gapRatio
    let maxBarH = bbox.height * 0.58

    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = bowlLeftEdge + CGFloat(i) * (barW + gap)
        let barH = maxBarH * h
        let y = bowlCenterY - barH / 2
        bars.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: barW, height: barH),
                            cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    }

    // Waveform in cream/white so it reads through the navy D.
    ctx.saveGState()
    ctx.addPath(bars)
    ctx.setFillColor(NSColor(srgbRed: 0.985, green: 0.972, blue: 0.948, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - Main

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot.appendingPathComponent("scratch/icon-concepts", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Clean previous round's renders so the directory only contains current
// concepts — keeps the file listing in scratch tidy.
if let existing = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
    for url in existing where url.pathExtension == "png" {
        try? FileManager.default.removeItem(at: url)
    }
}

let renders: [(String, () -> CGImage)] = [
    ("concept-c1-dark-vibrant.png", renderC1),
    ("concept-c2-speech-bubble.png", renderC2),
    ("concept-c3-heavy-d.png", renderC3),
]

for (name, render) in renders {
    let image = render()
    try writePNG(image, to: outDir.appendingPathComponent(name))
    print("wrote \(name)")
}
