import AppKit
import SwiftTerm

/// Hosts a terminal view with padding around it, painted in the theme background, with the
/// block overlay layered on top.
final class TerminalContainerView: NSView {
    let terminalView: TerminalView

    var overlay: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let overlay { addSubview(overlay, positioned: .above, relativeTo: terminalView) }
            needsLayout = true
        }
    }

    var padding = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16) {
        didSet { layoutTerminal() }
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
        layoutTerminal()
    }

    /// Auto Layout doesn't always call layout() when only this view's frame changes, so the
    /// terminal (frame-based) is also resized directly whenever our size changes.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutTerminal()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTerminal()
    }

    private func layoutTerminal() {
        let rect = NSRect(
            x: padding.left,
            y: padding.top,
            width: max(0, bounds.width - padding.left - padding.right),
            height: max(0, bounds.height - padding.top - padding.bottom)
        )
        if terminalView.frame != rect {
            terminalView.frame = rect
        }
        overlay?.frame = bounds
    }

    /// Clicks in the padding focus the terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
    }
}
