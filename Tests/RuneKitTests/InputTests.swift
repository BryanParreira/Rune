import XCTest
@testable import RuneKit

final class CommandHistoryTests: XCTestCase {
    func testParsesPlainAndExtendedFormats() {
        let text = """
        ls -la
        : 1700000000:0;git status
        : 1700000001:3;echo one\\
        two
        : 1700000002:0;  \n
        """
        let entries = CommandHistory.parseZshHistory(Data(text.utf8))
        XCTAssertEqual(entries, ["ls -la", "git status", "echo one\ntwo"])
    }

    func testUnmetafy() {
        // "é" is C3 A9; zsh doesn't metafy that, but bytes 0x83–0x9F are stored as 0x83, byte^0x20.
        let meta = Data([0x65, 0x83, 0xA3, 0x66]) // 'e', meta(0x83), 'f'
        XCTAssertEqual(Array(CommandHistory.unmetafy(meta)), [0x65, 0x83, 0x66])
    }

    func testAppendDedupesAndTrims() {
        var h = CommandHistory(entries: ["a", "b", "a"], limit: 3)
        XCTAssertEqual(h.entries, ["b", "a"])
        h.append("  c  ")
        h.append("")
        h.append("d")
        XCTAssertEqual(h.entries, ["a", "c", "d"])
    }

    func testLargeHistoryLoadsQuickly() {
        let entries = (0..<200_000).map { "command \($0 % 50_000)" }
        let start = Date()
        let history = CommandHistory(entries: entries)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertEqual(history.entries.count, 10_000)
        XCTAssertEqual(history.entries.last, "command 49999")
    }

    func testHistoryFileLocation() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(CommandHistory.zshHistoryURL(environment: [:], home: home).path, "/Users/x/.zsh_history")
        XCTAssertEqual(CommandHistory.zshHistoryURL(environment: ["ZDOTDIR": "/z"], home: home).path, "/z/.zsh_history")
        XCTAssertEqual(CommandHistory.zshHistoryURL(environment: ["HISTFILE": "/h/hist", "ZDOTDIR": "/z"], home: home).path, "/h/hist")
    }

    func testNavigatorWalksAndRestoresDraft() {
        let h = CommandHistory(entries: ["one", "two", "three"])
        var nav = HistoryNavigator()
        XCTAssertNil(nav.newer(in: h))
        XCTAssertEqual(nav.older(in: h, current: "draft"), "three")
        XCTAssertEqual(nav.older(in: h, current: "three"), "two")
        XCTAssertEqual(nav.older(in: h, current: "two"), "one")
        XCTAssertNil(nav.older(in: h, current: "one"))
        XCTAssertEqual(nav.newer(in: h), "two")
        XCTAssertEqual(nav.newer(in: h), "three")
        XCTAssertEqual(nav.newer(in: h), "draft")
        XCTAssertFalse(nav.isBrowsing)
    }

    func testNavigatorEmptyHistory() {
        var nav = HistoryNavigator()
        XCTAssertNil(nav.older(in: CommandHistory(), current: "x"))
    }
}

final class PathCompletionTests: XCTestCase {
    private let fs: [String: [(name: String, isDirectory: Bool)]] = [
        "/work/": [("Documents", true), ("Downloads", true), ("notes.txt", false), (".hidden", false), ("My File.txt", false)],
        "/work/Documents/": [("report.pdf", false)],
        "/home/me/": [("src", true)],
    ]

    private func complete(_ text: String, cursor: Int? = nil) -> PathCompletion.Result? {
        PathCompletion.complete(text: text, cursor: cursor ?? (text as NSString).length, cwd: "/work", home: "/home/me") { path in
            let key = path.hasSuffix("/") ? path : path + "/"
            return self.fs[key.replacingOccurrences(of: "//", with: "/")] ?? []
        }
    }

    func testUniqueFileGetsTrailingSpace() {
        let r = complete("cat no")
        XCTAssertEqual(r?.replacement, "notes.txt ")
        XCTAssertEqual(r?.range, NSRange(location: 4, length: 2))
        XCTAssertEqual(r?.isUnique, true)
    }

    func testUniqueDirectoryGetsSlash() {
        XCTAssertEqual(complete("cd Doc")?.replacement, "Documents/")
    }

    func testCommonPrefixForMultipleMatches() {
        let r = complete("cd Do")
        XCTAssertEqual(r?.replacement, "Do")
        XCTAssertEqual(r?.candidates, ["Documents/", "Downloads/"])
        XCTAssertEqual(complete("cd D")?.replacement, "Do")
    }

    func testNestedPathAndHome() {
        XCTAssertEqual(complete("open Documents/re")?.replacement, "Documents/report.pdf ")
        XCTAssertEqual(complete("cd ~/s")?.replacement, "~/src/")
    }

    func testHiddenOnlyWithDotPrefix() {
        XCTAssertFalse(complete("ls ")?.candidates.contains(".hidden") ?? true)
        XCTAssertEqual(complete("cat .h")?.replacement, ".hidden ")
    }

    func testEscapesSpaces() {
        XCTAssertEqual(complete("cat My")?.replacement, "My\\ File.txt ")
        XCTAssertEqual(complete("cat My\\ F")?.replacement, "My\\ File.txt ")
    }

    func testNoMatch() {
        XCTAssertNil(complete("cat zzz"))
    }

    func testCompletesWordBeforeCursor() {
        let r = complete("cat no | wc", cursor: 6)
        XCTAssertEqual(r?.range, NSRange(location: 4, length: 2))
    }
}

final class GitInfoTests: XCTestCase {
    func testParseHead() {
        XCTAssertEqual(GitInfo.parseHead("ref: refs/heads/main\n"), "main")
        XCTAssertEqual(GitInfo.parseHead("ref: refs/heads/feature/x"), "feature/x")
        XCTAssertEqual(GitInfo.parseHead("0123456789abcdef0123456789abcdef01234567"), "0123456")
        XCTAssertNil(GitInfo.parseHead("garbage"))
    }

    func testFindsRepoFromSubdirectoryAndWorktreeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rune-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let git = repo.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/dev\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        let sub = repo.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(GitInfo.branch(at: sub.path), "dev")

        let worktree = root.appendingPathComponent("wt")
        let wtGitDir = root.appendingPathComponent("wtgit")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wtGitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/topic\n".utf8).write(to: wtGitDir.appendingPathComponent("HEAD"))
        try Data("gitdir: \(wtGitDir.path)\n".utf8).write(to: worktree.appendingPathComponent(".git"))
        XCTAssertEqual(GitInfo.branch(at: worktree.path), "topic")

        XCTAssertNil(GitInfo.branch(at: root.path))
    }
}

final class ConfigWriterTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("rune-writer-\(UUID().uuidString)/config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func testSetsSharedAndHostValues() throws {
        let writer = ConfigWriter(file: file)
        try writer.set("fontSize", to: 15)
        try writer.set("fontSize", to: 12, scope: .host("Laptop"))
        try writer.set("paddingX", to: 8, scope: .host("laptop"))
        XCTAssertEqual(writer.value("fontSize") as? Int, 15)
        XCTAssertEqual(writer.value("fontSize", scope: .host("LAPTOP")) as? Int, 12)

        // Round-trips through the loader with host overrides applied.
        let loader = ConfigLoader(paths: ConfigPaths(directory: file.deletingLastPathComponent()), hostnames: ["laptop"])
        let config = loader.load().config
        XCTAssertEqual(config.fontSize, 12)
        XCTAssertEqual(config.paddingX, 8)
    }

    func testRemovingHostValueDropsEmptyEntry() throws {
        let writer = ConfigWriter(file: file)
        try writer.set("fontSize", to: 12, scope: .host("mac"))
        try writer.set("fontSize", to: nil, scope: .host("mac"))
        XCTAssertNil(writer.value("fontSize", scope: .host("mac")))
        let hosts = try writer.readDocument()["hosts"] as? [String: Any]
        XCTAssertEqual(hosts?.isEmpty, true)
    }

    func testRefusesToOverwriteBrokenFile() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: file)
        XCTAssertThrowsError(try ConfigWriter(file: file).set("fontSize", to: 14))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{ broken")
    }

    func testZshIntegrationEnvironment() {
        var env = ["ZDOTDIR": "/Users/x/.config/zsh", "PATH": "/bin"]
        ShellEnvironment.addZshIntegration(to: &env, integrationDirectory: "/App/zsh", honorPrompt: false)
        XCTAssertEqual(env["ZDOTDIR"], "/App/zsh")
        XCTAssertEqual(env["RUNE_USER_ZDOTDIR"], "/Users/x/.config/zsh")
        XCTAssertEqual(env["RUNE_INTEGRATION_DIR"], "/App/zsh")
        XCTAssertEqual(env["RUNE_HONOR_PROMPT"], "0")

        var plain = ["PATH": "/bin"]
        ShellEnvironment.addZshIntegration(to: &plain, integrationDirectory: "/App/zsh", honorPrompt: true)
        XCTAssertNil(plain["RUNE_USER_ZDOTDIR"])
        XCTAssertEqual(plain["RUNE_HONOR_PROMPT"], "1")
    }
}
