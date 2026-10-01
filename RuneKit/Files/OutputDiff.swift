import Foundation

/// What changed between two runs of a command: a line diff of their outputs, shown like a
/// file diff (hunks with a few unchanged lines around each change).
public enum OutputDiff {
    /// Lines compared from the end of each output; longer outputs are cut from the top.
    public static let maxLines = 5_000

    /// - Parameter ignoreNumbers: treat lines that differ only in their digits as equal
    ///   (timings, timestamps, PIDs), so the real changes stand out.
    public static func compare(old: String, new: String, context: Int = 3, ignoreNumbers: Bool = false) -> GitDiff {
        let oldAll = old.components(separatedBy: "\n")
        let newAll = new.components(separatedBy: "\n")
        let oldLines = Array(oldAll.suffix(maxLines))
        let newLines = Array(newAll.suffix(maxLines))
        let oldBase = oldAll.count - oldLines.count
        let newBase = newAll.count - newLines.count
        let key: (String) -> String = ignoreNumbers ? normalizingNumbers : { $0 }
        let difference = newLines.map(key).difference(from: oldLines.map(key))

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        // Every line of both outputs in order: unchanged lines pair up between the two.
        var ops: [(kind: DiffLine.Kind, old: Int?, new: Int?)] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removedOffsets.contains(i) {
                ops.append((.removed, i, nil))
                i += 1
            } else if j < newLines.count, insertedOffsets.contains(j) {
                ops.append((.added, nil, j))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                ops.append((.context, i, j))
                i += 1
                j += 1
            } else {
                break
            }
        }

        // Keep changes plus `context` lines around them.
        var keep = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() where op.kind != .context {
            for k in max(0, index - context)...min(ops.count - 1, index + context) { keep[k] = true }
        }

        var lines: [DiffLine] = []
        var previousKept = -2
        for (index, op) in ops.enumerated() where keep[index] {
            if index != previousKept + 1 {
                let start = (op.new ?? op.old ?? 0) + newBase + 1
                lines.append(DiffLine(id: lines.count, kind: .hunk, oldNumber: nil, newNumber: nil, text: "from line \(start)"))
            }
            previousKept = index
            let text: String
            switch op.kind {
            case .removed: text = oldLines[op.old ?? 0]
            default: text = newLines[op.new ?? 0]
            }
            lines.append(DiffLine(id: lines.count, kind: op.kind,
                                  oldNumber: op.old.map { $0 + oldBase + 1 },
                                  newNumber: op.new.map { $0 + newBase + 1 },
                                  text: text))
        }
        return GitDiff(
            lines: lines,
            added: insertedOffsets.count,
            removed: removedOffsets.count,
            truncated: oldBase > 0 || newBase > 0
        )
    }

    /// Indices of the lines in `new` that weren't in `old` (in the same place).
    public static func changedLines(old: [String], new: [String], ignoreNumbers: Bool = false) -> IndexSet {
        let key: (String) -> String = ignoreNumbers ? normalizingNumbers : { $0 }
        var changed = IndexSet()
        for change in new.map(key).difference(from: old.map(key)) {
            if case .insert(let offset, _, _) = change { changed.insert(offset) }
        }
        return changed
    }

    /// Runs of digits (with decimals) replaced by one placeholder.
    static func normalizingNumbers(_ line: String) -> String {
        line.replacingOccurrences(of: #"\d+(?:[.,:]\d+)*"#, with: "#", options: .regularExpression)
    }
}
