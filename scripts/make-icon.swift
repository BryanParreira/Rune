#!/usr/bin/env swift
// Generates Resources/Assets.xcassets/AppIcon.appiconset from code (no external assets).
// Usage: swift scripts/make-icon.swift [--preview out.png]
//
// "Blocks" on obsidian: a matte black ceramic tile with three stacked command blocks — past
// output fading upward, and a solid input line with a prompt chevron and cursor cut into it.
// No glow, no color; just material, light from above, and precise shapes.
import AppKit

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { fatalError("gradient") }
    return g
}

/// Paints one white shape with a soft contact shadow so it sits on the surface.
func paint(_ ctx: CGContext, _ path: CGPath, unit u: CGFloat, alpha: CGFloat = 1, evenOdd: Bool = false) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -u * 0.05), blur: u * 0.1, color: rgb(0x000000, 0.5))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0xF2F2F0, alpha))
    if evenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
    ctx.restoreGState()
}

/// The Blocks mark inside `body` (u = body.width / 10).
func drawBlocks(_ ctx: CGContext, body: CGRect, unit u: CGFloat) {
    let x = body.minX + u * 2.2, width = u * 5.6, height = u * 1.25, corner = u * 0.32, gap = u * 0.42
    let baseY = body.minY + u * 2.3

    // Earlier blocks: shorter and dimmer the older they are.
    let older = CGRect(x: x, y: baseY + (height + gap) * 2, width: width * 0.78, height: height)
    let previous = CGRect(x: x, y: baseY + height + gap, width: width * 0.58, height: height)
    paint(ctx, CGPath(roundedRect: older, cornerWidth: corner, cornerHeight: corner, transform: nil), unit: u, alpha: 0.38)
    paint(ctx, CGPath(roundedRect: previous, cornerWidth: corner, cornerHeight: corner, transform: nil), unit: u, alpha: 0.62)

    // Input line: solid, with a prompt chevron and cursor cut out of it.
    let input = CGRect(x: x, y: baseY, width: width, height: height)
    let shape = CGMutablePath()
    shape.addPath(CGPath(roundedRect: input, cornerWidth: corner, cornerHeight: corner, transform: nil))
    let cx = input.minX + u * 0.55, cy = input.midY, arm = u * 0.34
    let chevron = CGMutablePath()
    chevron.move(to: CGPoint(x: cx, y: cy + arm))
    chevron.addLine(to: CGPoint(x: cx + arm * 0.95, y: cy))
    chevron.addLine(to: CGPoint(x: cx, y: cy - arm))
    shape.addPath(chevron.copy(strokingWithWidth: u * 0.17, lineCap: .square, lineJoin: .miter, miterLimit: 4))
    shape.addRect(CGRect(x: cx + u * 0.75, y: cy - arm, width: u * 0.55, height: u * 0.15))
    paint(ctx, shape, unit: u, evenOdd: true)
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("context") }

    // macOS icon grid: 824/1024 body.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let tile = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let u = body.width / 10

    // Soft contact shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.028, color: rgb(0x000000, 0.40))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0x101012))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()

    // Matte ceramic: a gentle top-to-bottom falloff…
    ctx.drawLinearGradient(gradient([rgb(0x2B2C30), rgb(0x18191C), rgb(0x0E0E10)], [0, 0.55, 1]),
                           start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    // …with a broad, very soft light pool upper-left.
    ctx.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.06), rgb(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: body.minX + body.width * 0.3, y: body.maxY - body.height * 0.25), startRadius: 0,
                           endCenter: CGPoint(x: body.minX + body.width * 0.3, y: body.maxY - body.height * 0.25), endRadius: body.width * 0.75, options: [])

    // Fine grain so the surface reads as material, not flat fill (deterministic).
    if size >= 128 {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let grain = max(1, s / 512)
        let count = Int(body.width * body.height / (grain * grain) / 6)
        for _ in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = body.minX + CGFloat(seed >> 40 & 0xFFFF) / 65535 * body.width
            let y = body.minY + CGFloat(seed >> 20 & 0xFFFF) / 65535 * body.height
            let light = (seed & 1) == 0
            ctx.setFillColor(rgb(light ? 0xFFFFFF : 0x000000, light ? 0.025 : 0.05))
            ctx.fill(CGRect(x: x, y: y, width: grain, height: grain))
        }
    }

    drawBlocks(ctx, body: body, unit: u)

    ctx.restoreGState()

    // Hairline edge of the tile: brighter on top, fading down.
    ctx.saveGState()
    ctx.addPath(tile.copy(strokingWithWidth: max(1, s / 400), lineCap: .round, lineJoin: .round, miterLimit: 1))
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.20), rgb(0xFFFFFF, 0.04)], [0, 1]),
                           start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("png") }
    return png
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), args.indices.contains(i + 1) {
    try render(size: 1024).write(to: URL(fileURLWithPath: args[i + 1]))
    print("Wrote preview \(args[i + 1])")
    exit(0)
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: pixels).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
    .write(to: assets.appendingPathComponent("Contents.json"))
print("Wrote \(iconSet.path)")
