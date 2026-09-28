import XCTest
@testable import RuneKit

final class CommandHighlighterTests: XCTestCase {
    private let known: Set<String> = ["git", "ls", "echo", "grep", "sudo", "cd"]

    private func kinds(_ text: String) -> [(String, CommandHighlighter.Kind)] {
        let ns = text as NSString
        return CommandHighlighter.tokenize(text) { self.known.contains($0) || CommandCatalog.builtins.contains($0) }
            .map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testCommandsAndArguments() {
        let k = kinds("git commit -m \"msg here\" --amend")
        XCTAssertEqual(k.map(\.0), ["git", "commit", "-m", "\"msg here\"", "--amend"])
        XCTAssertEqual(k.map(\.1), [.command, .argument, .option, .string, .option])
    }

    func testUnknownCommandIsFlagged() {
        XCTAssertEqual(kinds("gti status").first?.1, .unknownCommand)
    }

    func testPipelinesStartNewCommands() {
        let k = kinds("ls -la | grep foo && nope")
        XCTAssertEqual(k.filter { $0.1 == .command }.map(\.0), ["ls", "grep"])
        XCTAssertEqual(k.filter { $0.1 == .unknownCommand }.map(\.0), ["nope"])
        XCTAssertEqual(k.filter { $0.1 == .operatorToken }.map(\.0), ["|", "&&"])
    }

    func testRedirectionTargetIsNotACommand() {
        let k = kinds("echo hi > out.txt")
        XCTAssertEqual(k.last?.0, "out.txt")
        XCTAssertEqual(k.last?.1, .argument)
    }

    func testVariablesStringsAndComments() {
        let k = kinds("echo $HOME '${x}' # note")
        XCTAssertTrue(k.contains { $0.0 == "$HOME" && $0.1 == .variable })
        XCTAssertTrue(k.contains { $0.0 == "'${x}'" && $0.1 == .string })
        XCTAssertTrue(k.contains { $0.0 == "# note" && $0.1 == .comment })
    }

    func testAssignmentsAndPrefixCommands() {
        let k = kinds("FOO=1 sudo ls")
        XCTAssertEqual(k.map(\.1), [.variable, .command, .command])
    }

    func testBuiltinsAndReservedWords() {
        XCTAssertEqual(kinds("cd /tmp").first?.1, .command)
        XCTAssertEqual(kinds("if true; then echo; fi").filter { $0.1 == .unknownCommand }.count, 0)
    }

    func testUnterminatedQuoteDoesNotCrash() {
        let k = kinds("echo \"unterminated")
        XCTAssertEqual(k.last?.1, .string)
    }

    func testUnicodeRangesAreUTF16() {
        let text = "echo 'héllo' 日本"
        let tokens = CommandHighlighter.tokenize(text) { _ in true }
        let ns = text as NSString
        XCTAssertEqual(tokens.map { ns.substring(with: $0.range) }, ["echo", "'héllo'", "日本"])
    }
}

final class CommandCatalogTests: XCTestCase {
    func testLoadsPathAndShellNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("mytool").path, contents: Data())

        let catalog = CommandCatalog()
        XCTAssertFalse(catalog.contains("mytool"))
        catalog.loadExecutables(path: dir.path)
        XCTAssertTrue(catalog.contains("mytool"))
        XCTAssertTrue(catalog.contains("cd"), "builtins are always known")
        XCTAssertFalse(catalog.contains("gst"))
        catalog.setShellNames(["gst", "ll"])
        XCTAssertTrue(catalog.contains("gst"))

        // A best-effort seed must not replace a real load.
        catalog.loadExecutables(path: "/nonexistent", onlyIfEmpty: true)
        XCTAssertTrue(catalog.contains("mytool"))
    }
}

final class SuggestionTests: XCTestCase {
    func testMostRecentPrefixMatch() {
        let h = CommandHistory(entries: ["git status", "git stash pop", "ls -la", "git status -s"])
        XCTAssertEqual(h.suggestion(for: "git st"), "git status -s")
        XCTAssertEqual(h.suggestion(for: "git stas"), "git stash pop")
        XCTAssertEqual(h.suggestion(for: "l"), "ls -la")
        XCTAssertNil(h.suggestion(for: "ls -la"), "an exact match has nothing left to suggest")
        XCTAssertNil(h.suggestion(for: ""))
        XCTAssertNil(h.suggestion(for: " git"))
        XCTAssertNil(h.suggestion(for: "zzz"))
    }
}

final class InputStyleTests: XCTestCase {
    func testShellPromptRouting() {
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: false, commandRunning: false, typeInShell: true), .shellPrompt)
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: false, commandRunning: true, typeInShell: true), .shellPrompt)
        XCTAssertEqual(InputRouter.mode(integration: .pending, alternateScreen: false, commandRunning: false, typeInShell: true), .shellPrompt)
        XCTAssertEqual(InputRouter.mode(integration: .active, alternateScreen: true, commandRunning: true, typeInShell: true), .fullscreenApp)
        XCTAssertEqual(InputRouter.mode(integration: .unavailable, alternateScreen: false, commandRunning: false, typeInShell: true), .plainTerminal)
        XCTAssertFalse(InputMode.shellPrompt.editorVisible)
        XCTAssertTrue(InputMode.shellPrompt.keystrokesToTerminal)
    }

    func testInputModeConfigParsing() {
        var warnings: [String] = []
        XCTAssertEqual(RuneConfig(dictionary: ["inputMode": "shell"], warnings: &warnings).inputMode, .shell)
        XCTAssertEqual(RuneConfig(dictionary: ["inputMode": "EDITOR"], warnings: &warnings).inputMode, .editor)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(RuneConfig(dictionary: ["inputMode": "vim"], warnings: &warnings).inputMode, .editor)
        XCTAssertEqual(warnings.count, 1)
    }

    func testShellStyleForcesRealPrompt() {
        var env: [String: String] = [:]
        ShellEnvironment.addZshIntegration(to: &env, integrationDirectory: "/x", honorPrompt: false, typeInShell: true)
        XCTAssertEqual(env["RUNE_HONOR_PROMPT"], "1")
        XCTAssertEqual(env["RUNE_INPUT_MODE"], "shell")
    }

    func testNamesAndPathMarks() {
        XCTAssertEqual(ShellMarkParser.parseRune("names=gst ll la"), .shellNames(["gst", "ll", "la"]))
        XCTAssertEqual(ShellMarkParser.parseRune("path=/a:/b%20c"), .shellPath("/a:/b c"))
    }
}
