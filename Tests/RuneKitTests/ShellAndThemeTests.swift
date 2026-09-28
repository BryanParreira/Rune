import XCTest
@testable import RuneKit

final class ShellResolverTests: XCTestCase {
    private let everythingExists: (String) -> Bool = { _ in true }

    func testConfiguredShellWins() {
        let shell = ShellResolver.resolve(configured: "/opt/fish", environment: ["SHELL": "/bin/bash"], accountShell: "/bin/zsh", isExecutable: everythingExists)
        XCTAssertEqual(shell, "/opt/fish")
    }

    func testFallsBackToEnvThenAccountThenZsh() {
        XCTAssertEqual(ShellResolver.resolve(configured: nil, environment: ["SHELL": "/bin/bash"], accountShell: "/bin/ksh", isExecutable: everythingExists), "/bin/bash")
        XCTAssertEqual(ShellResolver.resolve(configured: nil, environment: [:], accountShell: "/bin/ksh", isExecutable: everythingExists), "/bin/ksh")
        XCTAssertEqual(ShellResolver.resolve(configured: nil, environment: [:], accountShell: nil, isExecutable: everythingExists), "/bin/zsh")
    }

    func testSkipsMissingOrRelativeShells() {
        let exists: (String) -> Bool = { $0 == "/bin/bash" }
        let shell = ShellResolver.resolve(configured: "/nope/shell", environment: ["SHELL": "zsh"], accountShell: "/bin/bash", isExecutable: exists)
        XCTAssertEqual(shell, "/bin/bash")
    }

    func testLoginArgv0() {
        XCTAssertEqual(ShellResolver.loginArgv0(for: "/bin/zsh"), "-zsh")
        XCTAssertEqual(ShellResolver.loginArgv0(for: "/opt/homebrew/bin/fish"), "-fish")
        XCTAssertTrue(ShellResolver.isZsh("/bin/zsh"))
        XCTAssertFalse(ShellResolver.isZsh("/bin/bash"))
    }

    func testEnvironmentSetsTerminalVarsAndStripsLeaks() {
        let env = ShellEnvironment.build(
            inherited: ["PATH": "/usr/bin", "TERM_PROGRAM": "vscode", "SHLVL": "3", "HOME": "/Users/x", "VSCODE_INJECTION": "1"],
            currentDirectory: "/tmp",
            appVersion: "1.2.3"
        )
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["TERM_PROGRAM"], "Rune")
        XCTAssertEqual(env["TERM_PROGRAM_VERSION"], "1.2.3")
        XCTAssertEqual(env["PWD"], "/tmp")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertNil(env["SHLVL"])
        XCTAssertNil(env["VSCODE_INJECTION"])
        XCTAssertTrue(ShellEnvironment.toArray(env).contains("TERM=xterm-256color"))
    }

    func testEnvironmentKeepsUserLang() {
        let env = ShellEnvironment.build(inherited: ["LANG": "de_DE.UTF-8", "HOME": "/h"], currentDirectory: "/", appVersion: "1")
        XCTAssertEqual(env["LANG"], "de_DE.UTF-8")
    }

    func testProcessExitDecoding() {
        XCTAssertEqual(ProcessExit(waitStatus: 0), .exited(0))
        XCTAssertEqual(ProcessExit(waitStatus: 1 << 8), .exited(1))
        XCTAssertEqual(ProcessExit(waitStatus: 127 << 8), .exited(127))
        XCTAssertEqual(ProcessExit(waitStatus: 9), .signaled(9))
        XCTAssertTrue(ProcessExit(waitStatus: 0).isClean)
    }
}

final class TabTitleTests: XCTestCase {
    func testAbbreviatesHome() {
        XCTAssertEqual(TabTitle.abbreviate(path: "/Users/a", home: "/Users/a"), "~")
        XCTAssertEqual(TabTitle.abbreviate(path: "/Users/a/src", home: "/Users/a/"), "~/src")
        XCTAssertEqual(TabTitle.abbreviate(path: "/Users/ab", home: "/Users/a"), "/Users/ab")
        XCTAssertEqual(TabTitle.make(user: "u", host: "h", path: "/Users/u/x", home: "/Users/u"), "u@h:~/x")
    }

    func testOSC7Parsing() {
        XCTAssertEqual(TabTitle.pathFromOSC7("file://mac.local/Users/u/My%20Dir"), "/Users/u/My Dir")
        XCTAssertEqual(TabTitle.pathFromOSC7("/tmp"), "/tmp")
        XCTAssertNil(TabTitle.pathFromOSC7("https://example.com/x"))
    }

    func testHostnameSplitting() {
        XCTAssertEqual(HostIdentity.shortHostname("studio.local"), "studio")
        XCTAssertEqual(HostIdentity.configMatchNames(network: "studio.local", local: nil), ["studio", "studio.local"])
        XCTAssertEqual(HostIdentity.configMatchNames(network: "studio", local: "Studio"), ["studio"])
        XCTAssertEqual(HostIdentity.configMatchNames(network: "d-10-0-1-5.lan", local: "Alexs-Mac"), ["d-10-0-1-5", "d-10-0-1-5.lan", "Alexs-Mac"])
    }

    func testCurrentDirectoryOfSelf() {
        let cwd = ProcessInfoReader.currentDirectory(of: getpid())
        XCTAssertEqual(cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertNil(ProcessInfoReader.currentDirectory(of: -1))
    }
}

final class ThemeTests: XCTestCase {
    func testHexParsing() {
        XCTAssertEqual(RGB(hex: "#0a0a0a"), RGB(10, 10, 10))
        XCTAssertEqual(RGB(hex: "fff"), RGB(255, 255, 255))
        XCTAssertNil(RGB(hex: "#12"))
        XCTAssertNil(RGB(hex: "zzzzzz"))
        XCTAssertEqual(RGB(0x0a, 0x0b, 0x0c).hex, "#0a0b0c")
    }

    func testBuiltInThemeIsComplete() {
        XCTAssertEqual(Theme.runeDark.ansi.count, 16)
        XCTAssertEqual(Theme.runeDark.background, RGB(hex: "#0a0a0a"))
    }

    func testUserThemeOverlaysAndWarns() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let themes = dir.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try Data(##"{"background": "#101820", "cursor": "nope", "ansi": ["#000"]}"##.utf8)
            .write(to: themes.appendingPathComponent("ocean.json"))

        var warnings: [String] = []
        let theme = ThemeLoader.load(named: "ocean", resourceDirectories: [dir], warnings: &warnings)
        XCTAssertEqual(theme.name, "ocean")
        XCTAssertEqual(theme.background, RGB(0x10, 0x18, 0x20))
        XCTAssertEqual(theme.cursor, Theme.runeDark.cursor)
        XCTAssertEqual(theme.ansi, Theme.runeDark.ansi)
        XCTAssertEqual(warnings.count, 2)
    }

    func testUnknownThemeFallsBack() {
        var warnings: [String] = []
        let theme = ThemeLoader.load(named: "missing", resourceDirectories: [], warnings: &warnings)
        XCTAssertEqual(theme, .runeDark)
        XCTAssertEqual(warnings.count, 1)
    }
}
