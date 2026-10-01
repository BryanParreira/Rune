import AppKit
import RuneKit
import SwiftTerm

/// Renders a block (its command, colored output and status) as a picture in the current theme,
/// for pasting into a chat, issue or doc. Made on this Mac: nothing is uploaded to share it.
enum BlockImage {
    static let maxOutputLines = 300
    static let maxColumns = 160

    /// One block in the picture.
    struct Section {
        let command: String
        /// Output rows in order; a row with `isWrapped` continues the one before it.
        let rows: [BufferLine]
        /// Output lines left out above `rows`.
        let omittedLines: Int
        let status: String
        let failed: Bool
    }

    struct Style {
        let terminalColumns: Int
        let theme: Theme
        let palette: ChromePalette
        let font: NSFont
        /// Mask secrets (hiding is on), except those the user revealed.
        let maskSecrets: Bool
        let revealed: Set<String>
    }

    /// The picture as PNG data, and how many secrets were masked in it.
    static func png(_ sections: [Section], style: Style) -> (data: Data, hidden: Int)? {
        guard !sections.isEmpty else { return nil }
        var hidden = 0
        let font = style.font
        let palette = style.palette
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let cellWidth = font.advancement(forGlyph: font.glyph(withName: "W")).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineHeightMultiple = 1.12
        let statusFont = NSFont.monospacedSystemFont(ofSize: max(10, font.pointSize - 2), weight: .regular)

        struct Laid {
            let command: NSAttributedString
            let output: NSAttributedString
            let status: NSAttributedString
            let failed: Bool
        }
        var longest = 0
        let laid: [Laid] = sections.map { section in
            let lines = logicalLines(section.rows, style: style, hidden: &hidden)
            longest = max(longest, section.command.count + 2, lines.map(\.length).max() ?? 0)

            let command = NSMutableAttributedString(string: "$ ", attributes: [.font: bold, .foregroundColor: palette.accent, .paragraphStyle: paragraph])
            var commandText = section.command.replacingOccurrences(of: "\n", with: "\n  ")
            if style.maskSecrets { commandText = maskSecrets(in: commandText, revealed: style.revealed, hidden: &hidden) }
            command.append(NSAttributedString(string: commandText, attributes: [.font: bold, .foregroundColor: palette.text, .paragraphStyle: paragraph]))

            let output = NSMutableAttributedString()
            if section.omittedLines > 0 {
                output.append(NSAttributedString(string: "… \(section.omittedLines.formatted()) earlier lines\n",
                                                 attributes: [.font: font, .foregroundColor: palette.hint]))
            }
            for (index, line) in lines.enumerated() {
                output.append(line)
                if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            }
            output.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: output.length))
            let status = NSAttributedString(string: section.status, attributes: [
                .font: statusFont, .foregroundColor: section.failed ? palette.error : palette.hint,
            ])
            return Laid(command: command, output: output, status: status, failed: section.failed)
        }
        let columns = min(maxColumns, max(48, min(longest, max(48, style.terminalColumns))))
        let textWidth = ceil(CGFloat(columns) * cellWidth)
        let signature = NSAttributedString(string: "made in Rune", attributes: [
            .font: NSFont(name: "Caveat", size: font.pointSize + 5) ?? NSFont.systemFont(ofSize: font.pointSize + 3),
            .foregroundColor: palette.secondary,
        ])

        let measure: (NSAttributedString) -> CGFloat = {
            $0.length == 0 ? 0 : ceil($0.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let pad: CGFloat = 26
        let gap: CGFloat = 12
        let statusHeight = ceil(max(statusFont.ascender - statusFont.descender, 12))
        let signatureHeight = ceil(signature.size().height)
        // Each section: command, output, status line; then a divider before the next.
        let heights = laid.map { (command: measure($0.command), output: measure($0.output)) }
        var total = pad
        for (index, height) in heights.enumerated() {
            total += height.command + gap
            if height.output > 0 { total += height.output + gap }
            total += statusHeight
            total += index < heights.count - 1 ? gap * 2 + 1 : 0
        }
        total += 8 + signatureHeight + pad - 10
        let size = NSSize(width: textWidth + pad * 2, height: total)

        let image = NSImage(size: size, flipped: true) { _ in
            let card = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
            style.theme.background.nsColor.setFill()
            shape.fill()
            var y = pad
            for (index, section) in laid.enumerated() {
                let top = y - (index == 0 ? pad : gap)
                let height = heights[index]
                section.command.draw(with: NSRect(x: pad, y: y, width: textWidth, height: height.command), options: [.usesLineFragmentOrigin, .usesFontLeading])
                y += height.command + gap
                if height.output > 0 {
                    section.output.draw(with: NSRect(x: pad, y: y, width: textWidth, height: height.output), options: [.usesLineFragmentOrigin, .usesFontLeading])
                    y += height.output + gap
                }
                section.status.draw(at: NSPoint(x: pad, y: y))
                y += statusHeight
                if section.failed {
                    // Flag pole beside the failed block, like in the terminal.
                    NSGraphicsContext.saveGraphicsState()
                    shape.addClip()
                    palette.error.setFill()
                    NSRect(x: 0, y: top, width: 4, height: y + gap - top).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                if index < laid.count - 1 {
                    y += gap
                    palette.outline.setFill()
                    NSRect(x: pad, y: y, width: textWidth, height: 1).fill()
                    y += 1 + gap
                }
            }
            palette.outline.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            // The handwritten signature, tilted like a margin note.
            let signatureSize = signature.size()
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: pad + textWidth - signatureSize.width / 2, yBy: size.height - pad + 10 - signatureHeight / 2)
            transform.rotate(byDegrees: -2.5)
            transform.concat()
            signature.draw(at: NSPoint(x: -signatureSize.width / 2, y: -signatureSize.height / 2))
            NSGraphicsContext.restoreGraphicsState()
            return true
        }

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: 2)]) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, hidden)
    }

    // MARK: - Output text

    /// Joins soft-wrapped rows into lines, keeping each cell's colors and style.
    private static func logicalLines(_ rows: [BufferLine], style content: Style, hidden: inout Int) -> [NSMutableAttributedString] {
        var lines: [NSMutableAttributedString] = []
        for row in rows {
            let text = attributed(row, content: content)
            if row.isWrapped, let last = lines.last {
                last.append(text)
            } else {
                lines.append(text)
            }
        }
        for line in lines {
            trimTrailingWhitespace(line)
            guard content.maskSecrets else { continue }
            for match in SecretRedactor.matches(in: line.string).reversed() {
                let secret = (line.string as NSString).substring(with: match.range)
                guard !content.revealed.contains(secret) else { continue }
                line.replaceCharacters(in: match.range, with: NSAttributedString(string: "[redacted \(match.kind)]", attributes: [
                    .font: content.font, .foregroundColor: content.palette.hint,
                ]))
                hidden += 1
            }
        }
        // Blank lines at the end (the spacer before the next prompt) add nothing.
        while let last = lines.last, last.string.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private static func attributed(_ line: BufferLine, content: Style) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var run = ""
        var runAttributes: [NSAttributedString.Key: Any] = [:]
        var runKey: Attribute?
        func flush() {
            if !run.isEmpty { out.append(NSAttributedString(string: run, attributes: runAttributes)) }
            run = ""
        }
        for column in 0..<min(line.count, content.terminalColumns) {
            let cell = line[column]
            // The second half of a wide character holds no text of its own.
            if cell.width == 0 { continue }
            var character = cell.getCharacter()
            if character == "\u{0}" { character = " " }
            if cell.attribute != runKey {
                flush()
                runKey = cell.attribute
                runAttributes = attributes(for: cell.attribute, content: content)
            }
            run.append(character)
        }
        flush()
        return out
    }

    private static func attributes(for attribute: Attribute, content: Style) -> [NSAttributedString.Key: Any] {
        let style = attribute.style
        var font = content.font
        if style.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if style.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var foreground = color(attribute.fg, theme: content.theme) ?? content.theme.foreground.nsColor
        var background = color(attribute.bg, theme: content.theme)
        if style.contains(.inverse) {
            let swapped = background ?? content.theme.background.nsColor
            background = foreground
            foreground = swapped
        }
        if style.contains(.dim) { foreground = foreground.withAlphaComponent(0.6) }
        var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        if let background { result[.backgroundColor] = background }
        if style.contains(.underline) { result[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return result
    }

    /// A cell color in the theme's palette (nil for the default color).
    private static func color(_ color: Attribute.Color, theme: Theme) -> NSColor? {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .trueColor(let red, let green, let blue):
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        case .ansi256(let code):
            let code = Int(code)
            if code < 16 { return code < theme.ansi.count ? theme.ansi[code].nsColor : nil }
            if code < 232 {
                // The xterm 6×6×6 color cube.
                let index = code - 16
                let level: (Int) -> CGFloat = { $0 == 0 ? 0 : CGFloat($0 * 40 + 55) / 255 }
                return NSColor(srgbRed: level(index / 36), green: level(index / 6 % 6), blue: level(index % 6), alpha: 1)
            }
            let gray = CGFloat(8 + (code - 232) * 10) / 255
            return NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
        }
    }

    private static func trimTrailingWhitespace(_ line: NSMutableAttributedString) {
        let string = line.string as NSString
        var end = string.length
        while end > 0, string.character(at: end - 1) == 0x20 { end -= 1 }
        if end < string.length { line.deleteCharacters(in: NSRange(location: end, length: string.length - end)) }
    }

    private static func maskSecrets(in text: String, revealed: Set<String>, hidden: inout Int) -> String {
        var result = text as NSString
        for match in SecretRedactor.matches(in: text).reversed() {
            guard !revealed.contains((text as NSString).substring(with: match.range)) else { continue }
            result = result.replacingCharacters(in: match.range, with: "[redacted \(match.kind)]") as NSString
            hidden += 1
        }
        return result as String
    }
}
