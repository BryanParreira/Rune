import Foundation

/// Popular color schemes, written out for Rune (their published palettes).
extension Theme {
    private static func scheme(_ name: String, background: String, foreground: String, cursor: String, selection: String,
                               accent: String, ansi: [String]) -> Theme {
        let rgb = { (hex: String) in RGB(hex: hex) ?? RGB(0, 0, 0) }
        return Theme(name: name, background: rgb(background), foreground: rgb(foreground), cursor: rgb(cursor),
                     selectionBackground: rgb(selection), selectionForeground: rgb(foreground), accent: rgb(accent),
                     ansi: ansi.map(rgb))
    }

    static let classics: [Theme] = [
        scheme("dracula", background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2", selection: "#44475a", accent: "#bd93f9", ansi: [
            "#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
            "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        scheme("solarized-dark", background: "#002b36", foreground: "#839496", cursor: "#93a1a1", selection: "#073642", accent: "#268bd2", ansi: [
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        scheme("solarized-light", background: "#fdf6e3", foreground: "#657b83", cursor: "#586e75", selection: "#eee8d5", accent: "#268bd2", ansi: [
            "#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
            "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        scheme("gruvbox-dark", background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2", selection: "#504945", accent: "#fabd2f", ansi: [
            "#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
            "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        scheme("gruvbox-light", background: "#fbf1c7", foreground: "#3c3836", cursor: "#3c3836", selection: "#d5c4a1", accent: "#b57614", ansi: [
            "#fbf1c7", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#7c6f64",
            "#928374", "#9d0006", "#79740e", "#b57614", "#076678", "#8f3f71", "#427b58", "#3c3836"]),
        scheme("nord", background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9", selection: "#434c5e", accent: "#88c0d0", ansi: [
            "#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
            "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        scheme("tokyo-night", background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5", selection: "#33467c", accent: "#7aa2f7", ansi: [
            "#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
            "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"]),
        scheme("catppuccin-mocha", background: "#1e1e2e", foreground: "#cdd6f4", cursor: "#f5e0dc", selection: "#45475a", accent: "#cba6f7", ansi: [
            "#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
            "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"]),
        scheme("catppuccin-latte", background: "#eff1f5", foreground: "#4c4f69", cursor: "#dc8a78", selection: "#acb0be", accent: "#8839ef", ansi: [
            "#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#acb0be",
            "#6c6f85", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#bcc0cc"]),
        scheme("one-dark", background: "#282c34", foreground: "#abb2bf", cursor: "#528bff", selection: "#3e4451", accent: "#61afef", ansi: [
            "#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
            "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
    ]

    static let classicNames: [String: String] = [
        "dracula": "Dracula", "solarized-dark": "Solarized Dark", "solarized-light": "Solarized Light",
        "gruvbox-dark": "Gruvbox Dark", "gruvbox-light": "Gruvbox Light", "nord": "Nord",
        "tokyo-night": "Tokyo Night", "catppuccin-mocha": "Catppuccin Mocha", "catppuccin-latte": "Catppuccin Latte",
        "one-dark": "One Dark",
    ]
}
