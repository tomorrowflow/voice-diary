#!/usr/bin/env swift
// Renders the C1 app icon (App Icon v2 — weekdays + month dot grid + mic)
// from Claude Design's "App Icon v2.html" handoff into a 1024×1024 PNG.
//
// Run from `ios/`:
//     swift scripts/build_app_icon.swift
//
// Output: Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// Geometry is a direct port of `IconC1` (320×320 viewBox) scaled by 3.2× to
// 1024×1024. iOS applies the squircle mask itself; we ship a square PNG that
// fills the full canvas with the black background.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let SIZE: CGFloat = 1024
let SCALE: CGFloat = SIZE / 320.0  // 3.2

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let iosRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fontURL = iosRoot.appendingPathComponent("Resources/Geist-Variable.ttf")
let outDir = iosRoot.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let outURL = outDir.appendingPathComponent("icon-1024.png")

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// Register the bundled Geist variable font so CoreText can resolve it.
var fontError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError) ||
        (fontError?.takeUnretainedValue()).flatMap({ CFErrorGetCode($0) == 105 /* already registered */ }) ?? false
else {
    if let err = fontError?.takeUnretainedValue() { FileHandle.standardError.write(Data("font registration failed: \(err)\n".utf8)) }
    exit(1)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(SIZE), height: Int(SIZE),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace,
    // App icons must be opaque (App Store rejects PNGs with alpha).
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { exit(1) }

// CoreGraphics has its origin in the bottom-left; SVG origin is top-left.
// Flip the Y axis so we can use SVG-style coordinates throughout.
ctx.translateBy(x: 0, y: SIZE)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}
func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

let bg = rgb(0x0B0B0B)
let red = rgb(0xEC2222)
let stroke = white(1)

// 1. Background fill.
ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: SIZE, height: SIZE))

// Coordinates in 320-space, scaled at draw-time.
func S(_ v: CGFloat) -> CGFloat { v * SCALE }

let cols = 7, rows = 5
let gridLeft: CGFloat = 52
let gridTop: CGFloat = 96
let cellW: CGFloat = 32, cellH: CGFloat = 32
let dotR: CGFloat = 4.5

// Pixel-accurate skip — drop dots that overlap the mic capsule (117–179, 110–214)
// or the stem (140–158, 230–262). Coordinates in the 320 viewBox.
func shouldSkip(_ cx: CGFloat, _ cy: CGFloat) -> Bool {
    if cx >= 117, cx <= 179, cy >= 110, cy <= 214 { return true }
    if cx >= 140, cx <= 158, cy >= 230, cy <= 262 { return true }
    return false
}

// 2. Weekday header letters: M D M D F S S
//    First five (Mon–Fri) at 40% white, weekend at 22%. Geist 15pt / 600.
let days = ["M", "D", "M", "D", "F", "S", "S"]
let labelSize: CGFloat = 15
let geistSemibold = CTFontCreateWithName("Geist-SemiBold" as CFString, S(labelSize), nil)

for (i, d) in days.enumerated() {
    let x = gridLeft + CGFloat(i) * cellW + cellW / 2
    let y: CGFloat = 72
    let alpha: CGFloat = i >= 5 ? 0.22 : 0.40
    let attrs: CFDictionary = [
        kCTFontAttributeName: geistSemibold,
        kCTForegroundColorAttributeName: white(alpha),
        kCTKernAttributeName: S(labelSize) * 0.04,  // letterSpacing 0.04em
    ] as CFDictionary
    let attr = CFAttributedStringCreate(nil, d as CFString, attrs)!
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    // Draw text in an un-flipped sub-context so glyphs aren't mirrored.
    ctx.saveGState()
    ctx.translateBy(x: S(x), y: S(y))
    ctx.scaleBy(x: 1, y: -1)
    // Center horizontally; vertical y in SVG sits on the text baseline.
    ctx.textPosition = CGPoint(x: -bounds.width / 2 - bounds.origin.x, y: 0)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// 3. Date dot grid (7×5), skipping cells that overlap the mic shape.
ctx.setFillColor(white(0.20))
for r in 0..<rows {
    for c in 0..<cols {
        let cx = gridLeft + CGFloat(c) * cellW + cellW / 2
        let cy = gridTop + CGFloat(r) * cellH + cellH / 2
        if shouldSkip(cx, cy) { continue }
        let rect = CGRect(
            x: S(cx - dotR), y: S(cy - dotR),
            width: S(dotR * 2), height: S(dotR * 2)
        )
        ctx.fillEllipse(in: rect)
    }
}

// 4. "Today" highlight at col 5, row 3 — larger, brighter dot.
do {
    let cx = gridLeft + 5 * cellW + cellW / 2
    let cy = gridTop + 3 * cellH + cellH / 2
    let rTo: CGFloat = 8
    ctx.setFillColor(white(0.55))
    ctx.fillEllipse(in: CGRect(
        x: S(cx - rTo), y: S(cy - rTo),
        width: S(rTo * 2), height: S(rTo * 2)
    ))
}

// 5. Mic glyph — group transform translate(108, 112), all coordinates relative.
let micOX: CGFloat = 108, micOY: CGFloat = 112
func MX(_ v: CGFloat) -> CGFloat { S(micOX + v) }
func MY(_ v: CGFloat) -> CGFloat { S(micOY + v) }

ctx.setStrokeColor(stroke)
ctx.setLineWidth(S(6))
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// 5a. Capsule body — rect(12, 2, 56, 96, rx=28) stroked.
let bodyRect = CGRect(x: MX(12), y: MY(2), width: S(56), height: S(96))
let bodyPath = CGPath(roundedRect: bodyRect,
                     cornerWidth: S(28), cornerHeight: S(28),
                     transform: nil)
ctx.addPath(bodyPath)
ctx.strokePath()

// 5b. Cradle arc — M -2 78 A 42 42 0 0 0 84 78
//     Half-circle centered at (41, 78) with radius 42, opening downward
//     (in SVG space — i.e. visually below the capsule body).
do {
    let cx = MX(41), cy = MY(78)
    let r = S(42)
    let arc = CGMutablePath()
    arc.addArc(center: CGPoint(x: cx, y: cy), radius: r,
               startAngle: .pi, endAngle: 0, clockwise: true)
    ctx.addPath(arc)
    ctx.strokePath()
}

// 5c. Stem — vertical line from (41, 128) to (41, 150).
ctx.move(to: CGPoint(x: MX(41), y: MY(128)))
ctx.addLine(to: CGPoint(x: MX(41), y: MY(150)))
ctx.strokePath()

// 5d. Recording dot — filled red, cx=40 cy=38 r=10.
ctx.setFillColor(red)
let recR: CGFloat = 10
ctx.fillEllipse(in: CGRect(
    x: MX(40 - recR), y: MY(38 - recR),
    width: S(recR * 2), height: S(recR * 2)
))

// 6. Encode and write PNG.
guard let cgImage = ctx.makeImage() else { exit(1) }
guard let dest = CGImageDestinationCreateWithURL(
    outURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { exit(1) }
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }

print("wrote \(outURL.path)")
