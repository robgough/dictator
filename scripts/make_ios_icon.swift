#!/usr/bin/env swift
// Renders the Dictator iOS app icon at 1024×1024, opaque, full-bleed.
// Run from the repo root: `swift scripts/make_ios_icon.swift`
//
// Why this exists separately from `make_icon.swift` (macOS): iOS app icons
// can't have an alpha channel (App Store Connect rejects them with error
// 90717), and iOS applies its own ~22%-radius rounded mask on top of the
// supplied bitmap. So the iOS icon needs to be a full-bleed RGB design
// with no transparency — iOS does the corner-rounding for us.
//
// Design matches the macOS icon: pale vertical gradient background
// (paper white → cool light grey) with a centred 9-bar voice waveform in
// the system-blue accent. The macOS version is clipped to a squircle path
// because the macOS icon shape is part of the design; here the gradient
// extends to all four corners and gets cropped by iOS at display time.

import AppKit
import CoreGraphics
import Foundation

private let pixels = 1024

private func renderIcon() -> CGImage {
    let s = CGFloat(pixels)
    let cs = CGColorSpaceCreateDeviceRGB()
    // `noneSkipLast` gives an RGBX context — no alpha channel.
    // CGImageDestination will emit an RGB PNG when handed this image,
    // which is what App Store Connect demands.
    let info = CGImageAlphaInfo.noneSkipLast.rawValue
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

    // Background gradient: paper white → cool light grey. Same colour stops
    // as the macOS icon, drawn over the full canvas instead of clipped to a
    // squircle (iOS rounds the corners on its own).
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

    // Waveform bars. Identical layout to the macOS icon — same heights,
    // gap ratio, cluster width, blue gradient, and drop shadow. iOS users
    // get visual continuity with the macOS app's icon.
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

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG destination"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write PNG"])
    }
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = repoRoot.appendingPathComponent(
    "Sources/DictatorIOS/Assets.xcassets/AppIcon.appiconset",
    isDirectory: true
)

let image = renderIcon()
let out = iconset.appendingPathComponent("icon-1024.png")
try writePNG(image, to: out)
print("wrote \(out.lastPathComponent) (\(pixels)×\(pixels))")
