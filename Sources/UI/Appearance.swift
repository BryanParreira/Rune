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

/// Chrome colors derived from the terminal theme (see docs/DESIGN.md, "Color system").
struct ChromePalette: Equatable {
    let background: NSColor
    let foreground: NSColor
    /// Main text: foreground @ 90%.
    let text: NSColor
    /// Secondary text: foreground @ 60%.
    let secondary: NSColor
    /// Hints and placeholders: foreground @ 40%.
    let hint: NSColor
    /// Disabled: foreground @ 20%.
    let disabled: NSColor
    /// Surfaces: background blended with foreground @ 5 / 10 / 15%.
    let surface1: NSColor
    let surface2: NSColor
    let surface3: NSColor
    /// Hairlines and borders: foreground @ 10%.
    let outline: NSColor
    let tabSelected: NSColor
    let tabHover: NSColor
    let accent: NSColor
    let error: NSColor
    let success: NSColor
    /// Light page (Paper) vs dark: picks the window appearance and a few contrast tweaks.
    let isLight: Bool
    /// Highlighter-pen yellow, for marks behind words and selected rows.
    let highlight: NSColor
    /// ANSI colors used for input syntax highlighting.
    let ansiYellow: NSColor
    let ansiBlue: NSColor
    let ansiMagenta: NSColor
    let ansiCyan: NSColor

    init(theme: Theme) {
        let fg = theme.foreground.nsColor
        let bg = theme.background.nsColor
        background = bg
        foreground = fg
        text = fg.withAlphaComponent(0.9)
        secondary = fg.withAlphaComponent(0.6)
        hint = fg.withAlphaComponent(0.4)
        disabled = fg.withAlphaComponent(0.2)
        surface1 = bg.blended(withFraction: 0.05, of: fg) ?? bg
        surface2 = bg.blended(withFraction: 0.10, of: fg) ?? bg
        surface3 = bg.blended(withFraction: 0.15, of: fg) ?? bg
        outline = fg.withAlphaComponent(0.10)
        tabSelected = fg.withAlphaComponent(0.06)
        tabHover = fg.withAlphaComponent(0.03)
        accent = theme.accent.nsColor
        isLight = theme.isLight
        highlight = NSColor(srgbRed: 250 / 255, green: 204 / 255, blue: 21 / 255, alpha: theme.isLight ? 0.45 : 0.28)
        error = theme.ansi.count > 1 ? theme.ansi[1].nsColor : NSColor(srgbRed: 188 / 255, green: 54 / 255, blue: 42 / 255, alpha: 1)
        success = theme.ansi.count > 2 ? theme.ansi[2].nsColor : NSColor(srgbRed: 28 / 255, green: 160 / 255, blue: 90 / 255, alpha: 1)
        func ansi(_ i: Int) -> NSColor { theme.ansi.count > i ? theme.ansi[i].nsColor : fg }
        ansiYellow = ansi(3)
        ansiBlue = ansi(4)
        ansiMagenta = ansi(5)
        ansiCyan = ansi(6)
    }

    /// Kept for the tab bar, which predates the token names.
    var separator: NSColor { outline }
}
