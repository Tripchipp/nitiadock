#!/usr/bin/env swift
// fork: draws NitiaDock's app icon, menu bar icon and the README icon.
//
// TRADEMARK.md reserves the Tungsten Edge logo, so the fork ships its own artwork, drawn here so
// it can be regenerated and tweaked without a design tool. The mark is what the app is: a dock
// plate holding app icons and one wide window card, with running dots underneath.
//
// Usage:
//   swift Scripts/fork_make_icons.swift                       # write the chosen variant into the project
//   swift Scripts/fork_make_icons.swift --preview <dir>       # write every variant as 1024px PNGs into <dir>
//   swift Scripts/fork_make_icons.swift --variant glass|paper|dusk
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

struct Variant {
    let name: String
    let background: [CGColor]      // top to bottom
    let glow: CGColor              // soft light behind the plate
    let plate: CGColor
    let plateStroke: CGColor
    let tiles: [[CGColor]]         // each app tile's gradient, top to bottom
    let card: CGColor
    let cardInk: CGColor
    let dot: CGColor
}

let variants: [Variant] = [
    Variant(
        name: "glass",
        background: [rgb(0x3B6BF5), rgb(0x1B2A6B)], glow: rgb(0x8FB4FF, 0.55),
        plate: rgb(0xFFFFFF, 0.26), plateStroke: rgb(0xFFFFFF, 0.55),
        tiles: [[rgb(0xFFD66B), rgb(0xFF9F2E)], [rgb(0x6EE7A8), rgb(0x1FB56B)]],
        card: rgb(0xFFFFFF, 0.92), cardInk: rgb(0x1B2A6B, 0.75), dot: rgb(0xFFFFFF)
    ),
    Variant(
        name: "paper",
        background: [rgb(0xFBFBFD), rgb(0xD9DEE8)], glow: rgb(0xFFFFFF, 0.9),
        plate: rgb(0x1D2330, 0.92), plateStroke: rgb(0x000000, 0.0),
        tiles: [[rgb(0x5AA9FF), rgb(0x2F6BF0)], [rgb(0xFF8A7A), rgb(0xF0483E)]],
        card: rgb(0xFFFFFF, 0.16), cardInk: rgb(0xFFFFFF, 0.9), dot: rgb(0xFFFFFF, 0.9)
    ),
    Variant(
        name: "dusk",
        background: [rgb(0x2A2440), rgb(0x0F1020)], glow: rgb(0xB06CFF, 0.45),
        plate: rgb(0xFFFFFF, 0.14), plateStroke: rgb(0xFFFFFF, 0.35),
        tiles: [[rgb(0xFF9EC4), rgb(0xE8457F)], [rgb(0x8CE0FF), rgb(0x2E9BE6)]],
        card: rgb(0xFFFFFF, 0.88), cardInk: rgb(0x2A2440, 0.75), dot: rgb(0xFFFFFF)
    ),
]

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], in rect: CGRect) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                               end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    context.restoreGState()
}

func appIcon(_ variant: Variant, pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Apple's macOS icon grid: an 824px tile in a 1024px canvas, corner radius 185.4, with a soft
    // drop shadow. Below 64px the shadow only muddies the edge, so it is left out.
    let u = size / 1024
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = rounded(tile, 185.4 * u)
    if pixels >= 64 {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 20 * u, color: rgb(0x000000, 0.30))
        context.addPath(tilePath)
        context.setFillColor(variant.background[1])
        context.fillPath()
        context.restoreGState()
    }
    fillGradient(context, tilePath, variant.background, in: tile)

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    // A soft light low in the tile, so the plate reads as sitting on something.
    let glow = CGGradient(colorsSpace: space, colors: [variant.glow, variant.glow.copy(alpha: 0)!] as CFArray, locations: nil)!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.minY + 300 * u), startRadius: 0,
                               endCenter: CGPoint(x: tile.midX, y: tile.minY + 300 * u), endRadius: 470 * u, options: [])
    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
    context.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.maxY - 330 * u), options: [])
    context.restoreGState()

    // The dock plate.
    let plate = CGRect(x: tile.minX + 64 * u, y: tile.minY + 280 * u, width: tile.width - 128 * u, height: 204 * u)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 36 * u, color: rgb(0x000000, 0.28))
    context.addPath(rounded(plate, 60 * u))
    context.setFillColor(variant.plate)
    context.fillPath()
    context.restoreGState()
    context.addPath(rounded(plate.insetBy(dx: 2 * u, dy: 2 * u), 58 * u))
    context.setStrokeColor(variant.plateStroke)
    context.setLineWidth(4 * u)
    context.strokePath()

    // Two app tiles, then one wide window card.
    let inset = 32 * u
    let side = plate.height - 2 * inset
    var x = plate.minX + inset
    var dotCenters: [CGFloat] = []
    for colors in variant.tiles {
        let rect = CGRect(x: x, y: plate.minY + inset, width: side, height: side)
        let path = rounded(rect, side * 0.26)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 12 * u, color: rgb(0x000000, 0.22))
        context.addPath(path)
        context.setFillColor(colors[1])
        context.fillPath()
        context.restoreGState()
        fillGradient(context, path, colors, in: rect)
        dotCenters.append(rect.midX)
        x += side + 22 * u
    }
    let card = CGRect(x: x, y: plate.minY + inset, width: plate.maxX - inset - x, height: side)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6 * u), blur: 12 * u, color: rgb(0x000000, 0.20))
    context.addPath(rounded(card, side * 0.26))
    context.setFillColor(variant.card)
    context.fillPath()
    context.restoreGState()
    // The card's "title": a small square and two lines.
    if pixels >= 64 {
        context.setFillColor(variant.cardInk)
        let glyph = CGRect(x: card.minX + 28 * u, y: card.midY - 32 * u, width: 64 * u, height: 64 * u)
        context.addPath(rounded(glyph, 18 * u))
        context.fillPath()
        let lineX = glyph.maxX + 22 * u
        for (offset, width) in [(10 * u, card.maxX - 30 * u - lineX), (-28 * u, (card.maxX - 30 * u - lineX) * 0.6)] {
            context.addPath(rounded(CGRect(x: lineX, y: card.midY + offset, width: width, height: 18 * u), 9 * u))
            context.fillPath()
        }
    }
    dotCenters.append(card.midX)

    // Running dots under the first tile and the card.
    context.setFillColor(variant.dot)
    for center in [dotCenters[0], dotCenters[2]] {
        context.fillEllipse(in: CGRect(x: center - 9 * u, y: plate.minY + 8 * u, width: 18 * u, height: 18 * u))
    }

    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

var arguments = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if let directory = value(after: "--preview") {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for variant in variants {
        try appIcon(variant, pixels: 1024).write(to: url.appendingPathComponent("icon-\(variant.name).png"))
        try appIcon(variant, pixels: 64).write(to: url.appendingPathComponent("icon-\(variant.name)-64.png"))
    }
    print("wrote previews into \(url.path)")
    exit(0)
}

let chosenName = value(after: "--variant") ?? "glass"
guard let chosen = variants.first(where: { $0.name == chosenName }) else {
    print("unknown variant \(chosenName); have: \(variants.map(\.name).joined(separator: ", "))")
    exit(2)
}

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    try appIcon(chosen, pixels: pixels).write(to: iconSet.appendingPathComponent("icon_\(pixels).png"))
}
let readmeIcon = root.appendingPathComponent("assets/icon.png")
try FileManager.default.createDirectory(at: readmeIcon.deletingLastPathComponent(), withIntermediateDirectories: true)
try appIcon(chosen, pixels: 512).write(to: readmeIcon)

// Menu bar icon: a vector template PDF on the same 20pt canvas as upstream's glyph
// (StatusMenuController sizes the status item from the image). A plate with two tiles and a card,
// knocked out by drawing them as even-odd holes (blend mode .clear is not representable in PDF).
let menuBarURL = assets.appendingPathComponent("MenuBarIcon.imageset/MenuBarIcon.pdf")
var box = CGRect(x: 0, y: 0, width: 20, height: 20)
let pdf = CGContext(menuBarURL as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
let glyph = CGMutablePath()
glyph.addPath(rounded(CGRect(x: 1, y: 5.5, width: 18, height: 9), 3))
glyph.addPath(rounded(CGRect(x: 3, y: 7.5, width: 3.6, height: 5), 1.2))
glyph.addPath(rounded(CGRect(x: 7.6, y: 7.5, width: 3.6, height: 5), 1.2))
glyph.addPath(rounded(CGRect(x: 12.2, y: 7.5, width: 4.8, height: 5), 1.2))
pdf.addPath(glyph)
pdf.setFillColor(.black)
pdf.fillPath(using: .evenOdd)
pdf.endPDFPage()
pdf.closePDF()

print("wrote the \(chosen.name) icon into \(assets.path) and assets/icon.png")
