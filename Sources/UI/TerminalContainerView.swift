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

    /// Rows at the bottom of the terminal pushed below this view's edge (and clipped), so the
    /// last line of output sits right above the input editor instead of the blank rows that
    /// hold Rune's invisible prompt.
    var hiddenBottomRows = 0 {
        didSet { if hiddenBottomRows != oldValue { layoutTerminal() } }
    }

    var background: NSColor = .black {
        didSet { layer?.backgroundColor = background.cgColor }
    }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.masksToBounds = true
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
        let size = NSSize(
            width: max(0, bounds.width - padding.left - padding.right),
            height: max(0, bounds.height - padding.top - padding.bottom)
        )
        // Size first: the terminal recomputes its row count from it.
        if terminalView.frame.size != size {
            terminalView.setFrameSize(size)
        }
        var origin = NSPoint(x: padding.left, y: padding.top)
        if hiddenBottomRows > 0 {
            // Shift down by the hidden rows plus the unused sliver below the last row, keeping
            // the height (and so the row count) unchanged.
            let rows = max(1, terminalView.getTerminal().rows)
            let cellHeight = terminalView.getOptimalFrameSize().height / CGFloat(rows)
            let unused = max(0, size.height - cellHeight * CGFloat(rows))
            origin.y += CGFloat(min(hiddenBottomRows, rows - 1)) * cellHeight + unused
        }
        if terminalView.frame.origin != origin {
            terminalView.setFrameOrigin(origin)
        }
        overlay?.frame = bounds
    }

    /// Clicks in the padding focus the terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
    }
}
