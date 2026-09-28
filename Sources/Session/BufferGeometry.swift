import AppKit
import SwiftTerm

/// Maps between SwiftTerm buffer rows and view coordinates.
///
/// Rows are stored as *scroll-invariant* rows (absolute row + lines trimmed from the top of
/// scrollback), so they stay valid while old output is discarded.
struct BufferGeometry {
    let terminal: Terminal
    let view: TerminalView

    /// Lines trimmed off the top of scrollback so far.
    var linesTrimmed: Int { terminal.buffer.totalLinesTrimmed }

    /// Number of lines currently in the buffer (scrollback + screen). SwiftTerm doesn't
    /// expose this directly, so probe `getScrollInvariantLine` (exponential + binary search).
    var lineCount: Int {
        let base = linesTrimmed
        guard terminal.getScrollInvariantLine(row: base) != nil else { return 0 }
        var lo = 1
        var hi = 1
        while terminal.getScrollInvariantLine(row: base + hi) != nil {
            lo = hi
            hi *= 2
        }
        // Invariant: row lo-1 exists (count >= lo), row hi does not (count <= hi).
        while lo < hi {
            let mid = (lo + hi) / 2
            if terminal.getScrollInvariantLine(row: base + mid) != nil {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Index in the buffer of the first row of the live screen.
    var screenTop: Int { max(0, lineCount - terminal.rows) }

    /// Scroll-invariant row of the cursor, plus its column.
    var cursorPosition: (row: Int, column: Int) {
        let cursor = terminal.getCursorLocation()
        return (linesTrimmed + screenTop + cursor.y, cursor.x)
    }

    /// Scroll-invariant row shown at the top of the view.
    var topVisibleRow: Int { linesTrimmed + terminal.getTopVisibleRow() }

    /// Height of one terminal row in points.
    var cellHeight: CGFloat {
        let rows = max(1, terminal.rows)
        return view.getOptimalFrameSize().height / CGFloat(rows)
    }

    /// Top edge (in `view`'s coordinates, which are not flipped) of a scroll-invariant row.
    func topY(ofRow row: Int) -> CGFloat {
        let index = CGFloat(row - topVisibleRow)
        return view.bounds.maxY - index * cellHeight
    }

    /// Row under a point in `view`'s coordinates.
    func row(atY y: CGFloat) -> Int {
        topVisibleRow + Int(floor((view.bounds.maxY - y) / cellHeight))
    }

    /// Text of rows `range` (scroll-invariant), joining soft-wrapped lines.
    func text(rows range: ClosedRange<Int>) -> String {
        var out = ""
        for row in range {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            if row != range.lowerBound, !line.isWrapped {
                out += "\n"
            }
            out += line.translateToString(trimRight: true)
        }
        return out.trimmingCharacters(in: .newlines)
    }
}
