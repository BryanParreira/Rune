#!/usr/bin/env swift
// Renders the DMG window background (1x and 2x) from code.
// Usage: swift scripts/make-dmg-background.swift <out-dir>
// Layout matches scripts/dmg-settings.py: 660×400 window, app icon at (165, 205),
// Applications at (495, 205), 128pt icons.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let width: CGFloat = 660, height: CGFloat = 400

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let w = Int(width * scale), h = Int(height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
    ctx.scaleBy(x: scale, y: scale)
    // CoreGraphics origin is bottom-left; Finder icon positions are measured from the top.
    func top(_ y: CGFloat) -> CGFloat { height - y }

    // Obsidian background with a soft light pool, matching the app icon.
    let bg = CGGradient(colorsSpace: space, colors: [rgb(0x232428), rgb(0x141517), rgb(0x0C0C0E)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: width / 2, y: height), end: CGPoint(x: width / 2, y: 0), options: [])
    let pool = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.06), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(pool, startCenter: CGPoint(x: width * 0.3, y: top(120)), startRadius: 0,
                           endCenter: CGPoint(x: width * 0.3, y: top(120)), endRadius: 420, options: [])

    // Fine grain.
    var seed: UInt64 = 0x2545F4914F6CDD1D
    for _ in 0..<Int(width * height / 7) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x = CGFloat(seed >> 40 & 0xFFFF) / 65535 * width
        let y = CGFloat(seed >> 20 & 0xFFFF) / 65535 * height
        ctx.setFillColor(rgb(seed & 1 == 0 ? 0xFFFFFF : 0x000000, seed & 1 == 0 ? 0.02 : 0.05))
        ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }

    // Soft pedestals under the two icons.
    for x in [165.0, 495.0] as [CGFloat] {
        let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.07), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: x, y: top(212)), startRadius: 0,
                               endCenter: CGPoint(x: x, y: top(212)), endRadius: 110, options: [])
    }

    // Arrow: a slim line with a chevron head, from the app toward Applications.
    let arrowY = top(200)
    let start = CGPoint(x: 262, y: arrowY), end = CGPoint(x: 398, y: arrowY)
    let line = CGMutablePath()
    line.move(to: start)
    line.addLine(to: end)
    line.move(to: CGPoint(x: end.x - 11, y: arrowY + 10))
    line.addLine(to: end)
    line.addLine(to: CGPoint(x: end.x - 11, y: arrowY - 10))
    ctx.saveGState()
    ctx.addPath(line.copy(strokingWithWidth: 2.2, lineCap: .round, lineJoin: .round, miterLimit: 4))
    ctx.clip()
    let arrowGradient = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0.55)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(arrowGradient, start: start, end: end, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // Type.
    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat, kern: CGFloat = 0) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: kern,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: (width - bounds.width) / 2, y: top(y))
        CTLineDraw(line, ctx)
    }
    draw("Rune", size: 26, weight: .semibold, color: NSColor(white: 1, alpha: 0.95), y: 62, kern: 0.3)
    draw("Drag Rune into Applications to install", size: 13, weight: .regular, color: NSColor(white: 1, alpha: 0.55), y: 86)
    draw("LOCAL-FIRST TERMINAL FOR MACOS", size: 9.5, weight: .medium, color: NSColor(white: 1, alpha: 0.28), y: 372, kern: 1.6)

    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatalError("png") }
    return png
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: outDir.appendingPathComponent("dmg-background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("dmg-background@2x.png"))
print("Wrote \(outDir.path)/dmg-background{,@2x}.png")
