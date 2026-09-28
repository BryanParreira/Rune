import AppKit
import SwiftTerm

/// Hosts a terminal view with padding around it, painted in the theme background.
final class TerminalContainerView: NSView {
    let terminalView: TerminalView

    var padding = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20) {
        didSet { needsLayout = true }
    }

    var background: NSColor = .black {
        didSet { layer?.backgroundColor = background.cgColor }
    }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let rect = NSRect(
            x: padding.left,
            y: padding.top,
            width: max(0, bounds.width - padding.left - padding.right),
            height: max(0, bounds.height - padding.top - padding.bottom)
        )
        if terminalView.frame != rect {
            terminalView.frame = rect
        }
    }

    /// Clicks in the padding focus the terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
    }
}
