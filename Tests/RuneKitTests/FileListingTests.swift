import XCTest
@testable import RuneKit

final class FileListingTests: XCTestCase {
    func testSortsFoldersFirstNaturally() {
        let entries = [
            FileListing.Entry(name: "file10.txt", path: "/p/file10.txt", isDirectory: false, isHidden: false),
            FileListing.Entry(name: "file2.txt", path: "/p/file2.txt", isDirectory: false, isHidden: false),
            FileListing.Entry(name: "Zeta", path: "/p/Zeta", isDirectory: true, isHidden: false),
            FileListing.Entry(name: "alpha", path: "/p/alpha", isDirectory: true, isHidden: false),
        ]
        XCTAssertEqual(FileListing.sorted(entries).map(\.name), ["alpha", "Zeta", "file2.txt", "file10.txt"])
    }

    func testHiddenAndNoiseFiltering() {
        let entries = [
            FileListing.Entry(name: ".env", path: "/p/.env", isDirectory: false, isHidden: true),
            FileListing.Entry(name: ".DS_Store", path: "/p/.DS_Store", isDirectory: false, isHidden: true),
            FileListing.Entry(name: "src", path: "/p/src", isDirectory: true, isHidden: false),
        ]
        XCTAssertEqual(FileListing.filter(entries, showHidden: false).map(\.name), ["src"])
        XCTAssertEqual(FileListing.filter(entries, showHidden: true).count, 3)
    }

    func testListsRealDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("b.swift").path, contents: Data())
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".hidden").path, contents: Data())
        let names = FileListing.entries(at: dir.path, showHidden: false).map(\.name)
        XCTAssertEqual(names, ["sub", "b.swift"])
        XCTAssertEqual(FileListing.entries(at: dir.path, showHidden: true).count, 3)
        XCTAssertTrue(FileListing.entries(at: dir.path + "/nope", showHidden: false).isEmpty)
    }

    func testShellQuoting() {
        XCTAssertEqual(FileListing.shellQuoted("/Users/me/src/app.swift"), "/Users/me/src/app.swift")
        XCTAssertEqual(FileListing.shellQuoted("/Users/me/My Docs"), "'/Users/me/My Docs'")
        XCTAssertEqual(FileListing.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
    }
}

final class GitStatusTests: XCTestCase {
    private func data(_ entries: [String]) -> Data {
        Data(entries.joined(separator: "\0").utf8) + Data([0])
    }

    func testParsesStatesAndAggregatesFolders() {
        let porcelain = data([
            " M Sources/App/main.swift",
            "?? docs/new.md",
            "A  RuneKit/New.swift",
            " D old.txt",
            "R  Sources/B.swift", "Sources/A.swift",
            "UU conflict.txt",
            "!! build/",
        ])
        let s = GitStatusSnapshot.parse(porcelain: porcelain, repoRoot: "/repo")
        XCTAssertEqual(s.state(for: "/repo/Sources/App/main.swift"), .modified)
        XCTAssertEqual(s.state(for: "/repo/docs/new.md"), .untracked)
        XCTAssertEqual(s.state(for: "/repo/RuneKit/New.swift"), .added)
        XCTAssertEqual(s.state(for: "/repo/old.txt"), .deleted)
        XCTAssertEqual(s.state(for: "/repo/Sources/B.swift"), .renamed)
        XCTAssertNil(s.state(for: "/repo/Sources/A.swift"), "rename source is not a separate entry")
        XCTAssertEqual(s.state(for: "/repo/conflict.txt"), .conflicted)
        XCTAssertNil(s.state(for: "/repo/build"), "ignored files are skipped")
        // Folders inherit the most important state inside them.
        XCTAssertEqual(s.state(for: "/repo/Sources/App"), .modified)
        XCTAssertEqual(s.state(for: "/repo/Sources"), .modified)
        XCTAssertEqual(s.state(for: "/repo/docs"), .untracked)
        XCTAssertEqual(s.state(for: "/repo"), .conflicted)
    }

    func testUntrackedFolderEntry() {
        let s = GitStatusSnapshot.parse(porcelain: data(["?? newdir/"]), repoRoot: "/r")
        XCTAssertEqual(s.state(for: "/r/newdir"), .untracked)
    }

    func testBadges() {
        XCTAssertEqual(GitFileState.modified.badge, "M")
        XCTAssertEqual(GitFileState.untracked.badge, "U")
    }
}
