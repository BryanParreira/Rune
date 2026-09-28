import AppKit
import RuneKit
import SwiftTerm

extension RGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// SwiftTerm colors use 16-bit channels.
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
}

extension CursorShape {
    func terminalStyle(blink: Bool) -> CursorStyle {
        switch (self, blink) {
        case (.bar, false): return .steadyBar
        case (.bar, true): return .blinkBar
        case (.block, false): return .steadyBlock
        case (.block, true): return .blinkBlock
        case (.underline, false): return .steadyUnderline
        case (.underline, true): return .blinkUnderline
        }
    }
}

/// Chrome colors derived from the terminal theme.
struct ChromePalette {
    let background: NSColor
    let foreground: NSColor
    let secondary: NSColor
    let tabSelected: NSColor
    let tabHover: NSColor
    let separator: NSColor

    init(theme: Theme) {
        background = theme.background.nsColor
        foreground = theme.foreground.nsColor
        secondary = theme.foreground.nsColor.withAlphaComponent(0.6)
        tabSelected = theme.foreground.nsColor.withAlphaComponent(0.06)
        tabHover = theme.foreground.nsColor.withAlphaComponent(0.03)
        separator = theme.foreground.nsColor.withAlphaComponent(0.09)
    }
}
