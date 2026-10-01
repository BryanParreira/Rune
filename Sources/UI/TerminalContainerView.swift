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

    /// Height of the whole pane. The terminal is sized from it, not from the space left over
    /// by the input area, welcome panel or AI card, so those can grow and shrink (a completion
    /// list, a second editor line) without resizing the PTY: no SIGWINCH, no reflow, no prompt
    /// redraw. The terminal stays anchored to the bottom and the chrome covers its top rows,
    /// which hold older output (or the blank padding a new session starts with).
    var paneHeight: CGFloat = 0 {
        didSet { if paneHeight != oldValue { layoutTerminal() } }
    }

    /// How far below its row grid the terminal is drawn, in points (less than a row): the
    /// part of a trackpad scroll that doesn't add up to a whole line yet, so scrolling glides
    /// instead of jumping a line at a time.
    var smoothOffset: CGFloat = 0 {
        didSet { if smoothOffset != oldValue { layoutTerminal() } }
    }

    /// Rows at the top of the terminal's viewport hidden above this view's edge.
    private(set) var coveredTopRows = 0

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
        let visibleHeight = max(0, bounds.height - padding.top - padding.bottom)
        let stableHeight = paneHeight - padding.top - padding.bottom
        let size = NSSize(
            width: max(0, bounds.width - padding.left - padding.right),
            height: max(visibleHeight, stableHeight)
        )
        // Size first: the terminal recomputes its row count from it.
        if terminalView.frame.size != size {
            terminalView.setFrameSize(size)
        }
        // Bottom-anchored: when the terminal is taller than the visible area, its top rows
        // slide up under the pane's top edge.
        var origin = NSPoint(x: padding.left, y: padding.top + visibleHeight - size.height)
        let rows = max(1, terminalView.getTerminal().rows)
        let cellHeight = terminalView.getOptimalFrameSize().height / CGFloat(rows)
        if hiddenBottomRows > 0 {
            // Shift down by the hidden rows plus the unused sliver below the last row, keeping
            // the height (and so the row count) unchanged.
            let unused = max(0, size.height - cellHeight * CGFloat(rows))
            origin.y += CGFloat(min(hiddenBottomRows, rows - 1)) * cellHeight + unused
        }
        coveredTopRows = origin.y < 0 && cellHeight > 0 ? min(rows - 1, Int(ceil(-origin.y / cellHeight - 0.01))) : 0
        origin.y += smoothOffset
        if terminalView.frame.origin != origin {
            terminalView.setFrameOrigin(origin)
            // Block backgrounds and headers are drawn relative to the terminal's position.
            overlay?.needsDisplay = true
        }
        overlay?.frame = bounds
    }

    /// Clicks in the padding focus the terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
    }
}
