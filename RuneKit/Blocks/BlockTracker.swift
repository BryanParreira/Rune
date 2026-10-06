import Foundation

/// A command and its output, located by scroll-invariant row numbers in the terminal buffer.
public struct Block: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case running
        case finished
    }

    public let id: Int
    public var command: String
    public var cwd: String
    public var host: String
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var state: State

    /// First row of the block (the spacer row that precedes the command).
    public var headerRow: Int
    /// First row of the command text.
    public var commandRow: Int
    /// First row of output.
    public var outputStartRow: Int
    /// Last row belonging to the block (inclusive). Nil while running.
    public var endRow: Int?

    /// Exit codes that mean "interrupted", not "failed": Ctrl-C (130) and SIGPIPE (141).
    public static let nonFailureExitCodes: Set<Int32> = [130, 141]

    public var isFailed: Bool {
        guard state == .finished, let exitCode else { return false }
        return exitCode != 0 && !Self.nonFailureExitCodes.contains(exitCode)
    }

    public func duration(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(startedAt)
    }

    /// Output rows, empty if the command printed nothing.
    public func outputRows(currentRow: Int) -> ClosedRange<Int>? {
        let last = endRow ?? currentRow
        return last >= outputStartRow ? outputStartRow...last : nil
    }

    public func lastRow(currentRow: Int) -> Int {
        max(endRow ?? currentRow, outputStartRow - 1)
    }
}

/// Where the cursor was when a mark arrived.
public struct MarkPosition: Equatable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Turns the stream of shell marks into blocks.
public final class BlockTracker {
    public private(set) var blocks: [Block] = []
    public private(set) var currentDirectory: String?
    public private(set) var integrationVersion: String?
    /// True between output start (C) and command finished (D).
    public var isCommandRunning: Bool { blocks.last?.state == .running }
    /// True once a prompt has been drawn and no command is running.
    public private(set) var isAtPrompt = false

    public let host: String
    public var maxBlocks = 5_000

    private var nextID = 1
    private var pendingHeaderRow: Int?
    private var pendingCommandRow: Int?
    private var pendingCommandText: String?

    public init(host: String) {
        self.host = host
    }

    /// Applies a mark. Returns true if anything observable changed.
    @discardableResult
    public func handle(_ mark: ShellMark, at position: MarkPosition, now: Date = Date()) -> Bool {
        switch mark {
        case .integrationReady(let version):
            integrationVersion = version
            return true

        case .currentDirectory(let path):
            guard path != currentDirectory else { return false }
            currentDirectory = path
            return true

        case .commandText(let text):
            pendingCommandText = text
            return false

        case .shellNames, .shellPath, .remoteHost, .remoteDirectory, .remoteReady, .typeahead, .pythonEnvironment:
            return false

        case .promptStart:
            // A prompt above the previous block means the screen was cleared or reset.
            if let last = blocks.last, position.row < last.headerRow {
                blocks.removeAll()
            }
            if isCommandRunning {
                // The shell never reported D (e.g. it was replaced); close the block here.
                finishRunning(exitCode: nil, at: position, now: now)
            }
            pendingHeaderRow = position.row
            pendingCommandRow = nil
            isAtPrompt = true
            return true

        case .commandStart:
            pendingCommandRow = position.row
            return false

        case .outputStart:
            guard let header = pendingHeaderRow else { return false }
            let commandRow = pendingCommandRow ?? header
            let block = Block(
                id: nextID,
                command: pendingCommandText ?? "",
                cwd: currentDirectory ?? "",
                host: host,
                startedAt: now,
                endedAt: nil,
                exitCode: nil,
                state: .running,
                headerRow: header,
                commandRow: commandRow,
                outputStartRow: max(position.row, commandRow + 1),
                endRow: nil
            )
            nextID += 1
            blocks.append(block)
            if blocks.count > maxBlocks { blocks.removeFirst(blocks.count - maxBlocks) }
            pendingHeaderRow = nil
            pendingCommandRow = nil
            pendingCommandText = nil
            isAtPrompt = false
            return true

        case .commandFinished(let exitCode):
            if isCommandRunning {
                finishRunning(exitCode: exitCode, at: position, now: now)
                return true
            }
            // Empty command line: nothing ran.
            pendingCommandText = nil
            return false
        }
    }

    private func finishRunning(exitCode: Int32?, at position: MarkPosition, now: Date) {
        guard var block = blocks.popLast() else { return }
        block.state = .finished
        block.exitCode = exitCode
        block.endedAt = now
        // If the cursor is at column 0 the output ended with a newline; that row is not ours.
        let last = position.column == 0 ? position.row - 1 : position.row
        block.endRow = max(last, block.outputStartRow - 1)
        blocks.append(block)
    }

    /// Re-maps every stored row (after a resize reflow or scrollback trimming). Blocks whose
    /// header can no longer be found are dropped.
    public func remapRows(_ map: (Int) -> Int?) {
        blocks = blocks.compactMap { block in
            guard let header = map(block.headerRow) else { return nil }
            var b = block
            let delta = header - block.headerRow
            b.headerRow = header
            b.commandRow = map(block.commandRow) ?? block.commandRow + delta
            b.outputStartRow = map(block.outputStartRow) ?? block.outputStartRow + delta
            if let end = block.endRow { b.endRow = map(end) ?? end + delta }
            return b
        }
        if let header = pendingHeaderRow { pendingHeaderRow = map(header) }
        if let row = pendingCommandRow { pendingCommandRow = map(row) }
    }

    /// Forgets all blocks (e.g. after Cmd-K clear).
    public func removeAll() {
        blocks.removeAll()
    }

    public func block(id: Int) -> Block? {
        blocks.first { $0.id == id }
    }

    /// Index of the block containing `row`, if any.
    public func blockIndex(containing row: Int, currentRow: Int) -> Int? {
        blocks.lastIndex { $0.headerRow <= row && row <= $0.lastRow(currentRow: currentRow) }
    }
}
