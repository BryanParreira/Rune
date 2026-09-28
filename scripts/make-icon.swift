#!/usr/bin/env swift
// Generates Resources/Assets.xcassets/AppIcon.appiconset from code (no external assets).
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Resources/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~185 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(colors: [
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.03, green: 0.03, blue: 0.04, alpha: 1),
    ])?.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    shape.lineWidth = max(1, s / 256)
    shape.stroke()

    // Raidō-style rune drawn from strokes: stem, angular bowl, diagonal leg.
    let u = body.width / 10
    let ox = body.minX + u * 3.3
    let oy = body.minY + u * 2.2
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: ox + x * u, y: oy + y * u) }
    let rune = NSBezierPath()
    rune.move(to: p(0, 0)); rune.line(to: p(0, 5.6))
    rune.move(to: p(0, 5.6)); rune.line(to: p(2.6, 4.3)); rune.line(to: p(0, 3.0))
    rune.move(to: p(0, 3.0)); rune.line(to: p(3.0, 0))
    rune.lineWidth = u * 0.62
    rune.lineCapStyle = .round
    rune.lineJoinStyle = .round

    let glow = NSShadow()
    glow.shadowColor = NSColor(srgbRed: 0.55, green: 0.75, blue: 1.0, alpha: 0.55)
    glow.shadowBlurRadius = u * 0.5
    glow.shadowOffset = .zero
    glow.set()
    NSColor(srgbRed: 0.78, green: 0.88, blue: 1.0, alpha: 1).setStroke()
    rune.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
    return png
}

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
