import AppKit

/// Vertically centers the window's close/minimize/zoom buttons in Rune's taller tab bar.
/// AppKit resets their position on resize and fullscreen transitions, so callers re-apply
/// it from the matching window delegate callbacks.
enum TrafficLights {
    static let leadingX: CGFloat = 14

    static func position(in window: NSWindow, barHeight: CGFloat) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let titlebarContainer = close.superview?.superview
        else { return }

        var containerFrame = titlebarContainer.frame
        containerFrame.size.height = barHeight
        containerFrame.origin.y = window.frame.height - barHeight
        titlebarContainer.frame = containerFrame

        let spacing = miniaturize.frame.minX - close.frame.minX
        let y = ((barHeight - close.frame.height) / 2).rounded()
        for (index, button) in [close, miniaturize, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: leadingX + CGFloat(index) * spacing, y: y))
        }
    }

    /// Horizontal space the buttons occupy, for insetting the tab bar.
    static func reservedWidth(in window: NSWindow) -> CGFloat {
        guard let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton)
        else { return 78 }
        let spacing = zoom.frame.minX - close.frame.minX
        return leadingX + spacing + zoom.frame.width + 18
    }
}
