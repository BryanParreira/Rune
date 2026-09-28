import XCTest
@testable import RuneKit

final class ShellMarkParserTests: XCTestCase {
    func testParses133Actions() {
        XCTAssertEqual(ShellMarkParser.parse133("A"), .promptStart)
        XCTAssertEqual(ShellMarkParser.parse133("A;k=i"), .promptStart)
        XCTAssertEqual(ShellMarkParser.parse133("B"), .commandStart)
        XCTAssertEqual(ShellMarkParser.parse133("C"), .outputStart)
        XCTAssertEqual(ShellMarkParser.parse133("D"), .commandFinished(exitCode: nil))
        XCTAssertEqual(ShellMarkParser.parse133("D;0"), .commandFinished(exitCode: 0))
        XCTAssertEqual(ShellMarkParser.parse133("D;127"), .commandFinished(exitCode: 127))
        XCTAssertEqual(ShellMarkParser.parse133("D;;aid=1"), .commandFinished(exitCode: nil))
    }

    func testRejectsUnknown133() {
        XCTAssertNil(ShellMarkParser.parse133(""))
        XCTAssertNil(ShellMarkParser.parse133("Z"))
        XCTAssertNil(ShellMarkParser.parse133("AB"))
    }

    func testParsesRunePayloads() {
        XCTAssertEqual(ShellMarkParser.parseRune("hello=1"), .integrationReady(version: "1"))
        XCTAssertEqual(ShellMarkParser.parseRune("cwd=/tmp/a%20b"), .currentDirectory("/tmp/a b"))
        XCTAssertEqual(ShellMarkParser.parseRune("cmd=echo a=b%0Aecho %25"), .commandText("echo a=b\necho %"))
        XCTAssertNil(ShellMarkParser.parseRune("cwd="))
        XCTAssertNil(ShellMarkParser.parseRune("nothing"))
        XCTAssertNil(ShellMarkParser.parseRune("other=1"))
    }

    func testPercentDecodeHandlesUTF8AndMalformed() {
        XCTAssertEqual(ShellMarkParser.percentDecode("caf%C3%A9"), "café")
        XCTAssertEqual(ShellMarkParser.percentDecode("100%"), "100%")
        XCTAssertEqual(ShellMarkParser.percentDecode("%zz"), "%zz")
        XCTAssertEqual(ShellMarkParser.percentDecode("日本"), "日本")
    }
}

final class BlockTrackerTests: XCTestCase {
    private func at(_ row: Int, _ column: Int = 0) -> MarkPosition { MarkPosition(row: row, column: column) }

    /// Simulates one prompt → command → output → finish cycle as the zsh integration emits it.
    private func run(_ t: BlockTracker, header: Int, command: String, outputLines: Int, exit: Int32, start: Date, seconds: TimeInterval) {
        t.handle(.promptStart, at: at(header), now: start)
        t.handle(.commandStart, at: at(header + 1), now: start)
        t.handle(.commandText(command), at: at(header + 1), now: start)
        t.handle(.outputStart, at: at(header + 2), now: start)
        t.handle(.commandFinished(exitCode: exit), at: at(header + 2 + outputLines), now: start.addingTimeInterval(seconds))
    }

    func testFullCycleCreatesFinishedBlock() {
        let t = BlockTracker(host: "mac")
        t.handle(.currentDirectory("/tmp"), at: at(0))
        let start = Date(timeIntervalSince1970: 1000)
        run(t, header: 0, command: "ls", outputLines: 3, exit: 0, start: start, seconds: 1.5)

        XCTAssertEqual(t.blocks.count, 1)
        let b = t.blocks[0]
        XCTAssertEqual(b.command, "ls")
        XCTAssertEqual(b.cwd, "/tmp")
        XCTAssertEqual(b.host, "mac")
        XCTAssertEqual(b.headerRow, 0)
        XCTAssertEqual(b.commandRow, 1)
        XCTAssertEqual(b.outputStartRow, 2)
        XCTAssertEqual(b.endRow, 4)
        XCTAssertEqual(b.outputRows(currentRow: 99), 2...4)
        XCTAssertEqual(b.exitCode, 0)
        XCTAssertEqual(b.state, .finished)
        XCTAssertEqual(b.duration(), 1.5, accuracy: 0.001)
        XCTAssertFalse(b.isFailed)
        XCTAssertFalse(t.isCommandRunning)
    }

    func testRunningStateBetweenCAndD() {
        let t = BlockTracker(host: "h")
        t.handle(.promptStart, at: at(0))
        XCTAssertTrue(t.isAtPrompt)
        t.handle(.commandStart, at: at(1))
        t.handle(.outputStart, at: at(2))
        XCTAssertTrue(t.isCommandRunning)
        XCTAssertFalse(t.isAtPrompt)
        XCTAssertNil(t.blocks[0].endRow)
        t.handle(.commandFinished(exitCode: 0), at: at(3))
        XCTAssertFalse(t.isCommandRunning)
    }

    func testFailureRulesIgnoreInterruptAndSigpipe() {
        let t = BlockTracker(host: "h")
        let now = Date()
        run(t, header: 0, command: "false", outputLines: 0, exit: 1, start: now, seconds: 0)
        run(t, header: 3, command: "sleep 9", outputLines: 0, exit: 130, start: now, seconds: 0)
        run(t, header: 6, command: "yes | head", outputLines: 1, exit: 141, start: now, seconds: 0)
        XCTAssertEqual(t.blocks.map(\.isFailed), [true, false, false])
    }

    func testCommandWithoutOutputHasNoOutputRows() {
        let t = BlockTracker(host: "h")
        run(t, header: 0, command: "cd /", outputLines: 0, exit: 0, start: Date(), seconds: 0)
        XCTAssertEqual(t.blocks[0].endRow, 1)
        XCTAssertNil(t.blocks[0].outputRows(currentRow: 10))
    }

    func testOutputWithoutTrailingNewlineKeepsLastRow() {
        let t = BlockTracker(host: "h")
        t.handle(.promptStart, at: at(0))
        t.handle(.commandStart, at: at(1))
        t.handle(.outputStart, at: at(2))
        t.handle(.commandFinished(exitCode: 0), at: at(2, 5))
        XCTAssertEqual(t.blocks[0].endRow, 2)
    }

    func testEmptyEnterMakesNoBlock() {
        let t = BlockTracker(host: "h")
        t.handle(.promptStart, at: at(0))
        t.handle(.commandStart, at: at(1))
        t.handle(.commandFinished(exitCode: nil), at: at(2))
        t.handle(.promptStart, at: at(2))
        XCTAssertTrue(t.blocks.isEmpty)
    }

    func testPromptAboveLastBlockMeansClearedScreen() {
        let t = BlockTracker(host: "h")
        run(t, header: 10, command: "ls", outputLines: 2, exit: 0, start: Date(), seconds: 0)
        t.handle(.promptStart, at: at(0))
        XCTAssertTrue(t.blocks.isEmpty)
    }

    func testMissingFinishIsClosedByNextPrompt() {
        let t = BlockTracker(host: "h")
        t.handle(.promptStart, at: at(0))
        t.handle(.commandStart, at: at(1))
        t.handle(.outputStart, at: at(2))
        t.handle(.promptStart, at: at(6))
        XCTAssertEqual(t.blocks[0].state, .finished)
        XCTAssertNil(t.blocks[0].exitCode)
        XCTAssertEqual(t.blocks[0].endRow, 5)
    }

    func testRemapRowsShiftsAndDrops() {
        let t = BlockTracker(host: "h")
        run(t, header: 0, command: "a", outputLines: 1, exit: 0, start: Date(), seconds: 0)
        run(t, header: 4, command: "b", outputLines: 1, exit: 0, start: Date(), seconds: 0)
        // Row 0 is gone; everything else moves down by 2.
        t.remapRows { $0 == 0 ? nil : $0 + 2 }
        XCTAssertEqual(t.blocks.count, 1)
        XCTAssertEqual(t.blocks[0].command, "b")
        XCTAssertEqual(t.blocks[0].headerRow, 6)
        XCTAssertEqual(t.blocks[0].outputStartRow, 8)
    }

    func testBlockIndexContainingRow() {
        let t = BlockTracker(host: "h")
        run(t, header: 0, command: "a", outputLines: 2, exit: 0, start: Date(), seconds: 0)
        run(t, header: 5, command: "b", outputLines: 1, exit: 0, start: Date(), seconds: 0)
        XCTAssertEqual(t.blockIndex(containing: 3, currentRow: 20), 0)
        XCTAssertEqual(t.blockIndex(containing: 6, currentRow: 20), 1)
        XCTAssertNil(t.blockIndex(containing: 15, currentRow: 20))
    }

    func testIntegrationReadyAndCwd() {
        let t = BlockTracker(host: "h")
        XCTAssertTrue(t.handle(.integrationReady(version: "1"), at: at(0)))
        XCTAssertEqual(t.integrationVersion, "1")
        XCTAssertTrue(t.handle(.currentDirectory("/a"), at: at(0)))
        XCTAssertFalse(t.handle(.currentDirectory("/a"), at: at(0)))
    }
}

final class InputRouterTests: XCTestCase {
    func testRouting() {
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: false, commandRunning: false), .editor)
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: false, commandRunning: true), .runningCommand)
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: true, commandRunning: true), .fullscreenApp)
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: true, commandRunning: false), .fullscreenApp)
        XCTAssertEqual(InputRouter.mode(integration: .pending, alternateScreen: false, commandRunning: false), .editor)
        XCTAssertEqual(InputRouter.mode(integration: .unavailable, alternateScreen: false, commandRunning: false), .plainTerminal)
        XCTAssertEqual(InputRouter.mode(integration: .unavailable, alternateScreen: true, commandRunning: false), .fullscreenApp)
    }

    func testModeProperties() {
        XCTAssertTrue(InputMode.editor.editorVisible)
        XCTAssertFalse(InputMode.editor.keystrokesToTerminal)
        XCTAssertTrue(InputMode.runningCommand.editorVisible)
        XCTAssertTrue(InputMode.runningCommand.keystrokesToTerminal)
        XCTAssertFalse(InputMode.fullscreenApp.editorVisible)
        XCTAssertTrue(InputMode.fullscreenApp.keystrokesToTerminal)
        XCTAssertFalse(InputMode.plainTerminal.editorVisible)
        XCTAssertTrue(InputMode.plainTerminal.keystrokesToTerminal)
    }
}
