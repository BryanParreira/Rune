import XCTest
@testable import RuneKit

final class ConfigMergeTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var paths: ConfigPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rune-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        paths = ConfigPaths(directory: home.appendingPathComponent(".config/rune", isDirectory: true))
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func loader(hosts: [String] = ["laptop", "laptop.local"]) -> ConfigLoader {
        ConfigLoader(paths: paths, hostnames: hosts, home: home)
    }

    // MARK: - Defaults / first launch

    func testMissingFileGivesDefaultsWithoutWarnings() {
        let result = loader().load()
        XCTAssertEqual(result.config, .defaults)
        XCTAssertEqual(result.warnings, [])
    }

    func testEnsureDefaultConfigWritesParsableFileOnce() throws {
        XCTAssertTrue(try loader().ensureDefaultConfig())
        XCTAssertFalse(try loader().ensureDefaultConfig())
        let result = loader().load()
        XCTAssertEqual(result.config, .defaults)
        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.themesDirectory.path))
    }

    func testDefaultsMatchSpec() {
        let c = RuneConfig.defaults
        XCTAssertEqual(c.paddingX, 16)
        XCTAssertEqual(c.cursorStyle, .bar)
        XCTAssertFalse(c.cursorBlink)
        XCTAssertNil(c.shell)
        XCTAssertNil(c.syncPath)
    }

    // MARK: - Base file

    func testBaseFileOverridesDefaults() throws {
        try write(#"{"fontSize": 15, "cursorStyle": "block", "theme": "mine"}"#, to: paths.configFile)
        let c = loader().load().config
        XCTAssertEqual(c.fontSize, 15)
        XCTAssertEqual(c.cursorStyle, .block)
        XCTAssertEqual(c.theme, "mine")
        XCTAssertEqual(c.paddingX, 16, "unspecified keys keep defaults")
    }

    func testInvalidJSONFallsBackToDefaultsWithWarning() throws {
        try write(#"{"fontSize": 15,,, oops"#, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config, .defaults)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("not valid JSON"))
    }

    func testNonObjectJSONWarns() throws {
        try write("[1, 2, 3]", to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config, .defaults)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testEmptyFileIsDefaults() throws {
        try write("  \n", to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config, .defaults)
        XCTAssertEqual(result.warnings, [])
    }

    func testCommentsAndTrailingCommasAreTolerated() throws {
        try write("""
        {
          // bigger text
          "fontSize": 16,
        }
        """, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config.fontSize, 16)
        XCTAssertEqual(result.warnings, [])
    }

    func testInvalidFieldsKeepDefaultsIndividually() throws {
        try write(#"{"fontSize": "big", "paddingX": 9999, "cursorStyle": "triangle", "cursorBlink": 1, "paddingY": 4, "mystery": true, "_comment": "ok"}"#, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config.fontSize, RuneConfig.defaults.fontSize)
        XCTAssertEqual(result.config.paddingX, RuneConfig.defaults.paddingX)
        XCTAssertEqual(result.config.cursorStyle, .bar)
        XCTAssertFalse(result.config.cursorBlink)
        XCTAssertEqual(result.config.paddingY, 4, "valid fields still apply")
        XCTAssertEqual(result.warnings.count, 5, "\(result.warnings)")
        XCTAssertTrue(result.warnings.contains { $0.contains("mystery") })
        XCTAssertFalse(result.warnings.contains { $0.contains("_comment") })
    }

    func testNullAndEmptyShellMeanUnset() throws {
        try write(#"{"shell": "  "}"#, to: paths.configFile)
        XCTAssertNil(loader().load().config.shell)
        try write(#"{"shell": null}"#, to: paths.configFile)
        XCTAssertNil(loader().load().config.shell)
    }

    // MARK: - Per-host overrides

    func testHostOverrideAppliesForMatchingHostOnly() throws {
        try write("""
        {"fontSize": 13, "hosts": {"LAPTOP": {"fontSize": 12}, "desktop": {"fontSize": 18}}}
        """, to: paths.configFile)
        XCTAssertEqual(loader(hosts: ["laptop"]).load().config.fontSize, 12, "case-insensitive match")
        XCTAssertEqual(loader(hosts: ["desktop"]).load().config.fontSize, 18)
        XCTAssertEqual(loader(hosts: ["other"]).load().config.fontSize, 13)
    }

    func testFullHostnameBeatsShortHostname() throws {
        try write("""
        {"hosts": {"laptop": {"fontSize": 12, "paddingX": 8}, "laptop.local": {"fontSize": 11}}}
        """, to: paths.configFile)
        let c = loader(hosts: ["laptop", "laptop.local"]).load().config
        XCTAssertEqual(c.fontSize, 11)
        XCTAssertEqual(c.paddingX, 8)
    }

    func testHostOverrideCannotChangeSyncPathOrNestHosts() throws {
        try write("""
        {"hosts": {"laptop": {"syncPath": "/elsewhere", "hosts": {"laptop": {"fontSize": 30}}, "fontSize": 14}}}
        """, to: paths.configFile)
        let result = loader().load()
        XCTAssertNil(result.config.syncPath)
        XCTAssertEqual(result.config.fontSize, 14)
    }

    func testMalformedHostsWarns() throws {
        try write(#"{"hosts": ["laptop"]}"#, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config, .defaults)
        XCTAssertEqual(result.warnings.count, 1)
    }

    // MARK: - Sync folder

    func testSyncFolderReplacesLocalConfig() throws {
        let sync = root.appendingPathComponent("Dotfiles/rune", isDirectory: true)
        try write(#"{"fontSize": 20, "theme": "synced", "hosts": {"laptop": {"paddingX": 4}}}"#, to: sync.appendingPathComponent("config.json"))
        try write(#"{"syncPath": "\#(sync.path)", "paddingY": 30}"#, to: paths.configFile)

        let result = loader().load()
        XCTAssertEqual(result.config.fontSize, 20)
        XCTAssertEqual(result.config.theme, "synced")
        XCTAssertEqual(result.config.paddingX, 4, "host overrides from the synced file apply")
        XCTAssertEqual(result.config.paddingY, RuneConfig.defaults.paddingY, "local settings are replaced, not merged")
        XCTAssertEqual(result.config.syncPath, sync.path)
        XCTAssertEqual(result.activeSyncDirectory?.standardizedFileURL, sync.standardizedFileURL)
        XCTAssertEqual(result.resourceDirectories.first?.standardizedFileURL, sync.standardizedFileURL)
        XCTAssertEqual(result.warnings, [])
    }

    func testSyncPathSupportsTilde() throws {
        let sync = home.appendingPathComponent("dotfiles/rune", isDirectory: true)
        try write(#"{"fontSize": 17}"#, to: sync.appendingPathComponent("config.json"))
        try write(#"{"syncPath": "~/dotfiles/rune"}"#, to: paths.configFile)
        XCTAssertEqual(loader().load().config.fontSize, 17)
    }

    func testMissingSyncFolderFallsBackToLocalWithWarning() throws {
        try write(#"{"syncPath": "~/nope", "fontSize": 15}"#, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config.fontSize, 15)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertNil(result.activeSyncDirectory)
    }

    func testInvalidSyncedConfigFallsBackToLocal() throws {
        let sync = home.appendingPathComponent("sync", isDirectory: true)
        try write("{nope", to: sync.appendingPathComponent("config.json"))
        try write(#"{"syncPath": "~/sync", "fontSize": 15}"#, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config.fontSize, 15)
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertNotNil(result.activeSyncDirectory, "themes can still come from the folder")
    }

    func testSyncFolderWithoutConfigKeepsLocalButUsesItsThemes() throws {
        let sync = home.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try write(#"{"syncPath": "~/sync", "fontSize": 15}"#, to: paths.configFile)
        let result = loader().load()
        XCTAssertEqual(result.config.fontSize, 15)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.resourceDirectories.count, 2)
    }

    // MARK: - Paths

    func testStandardPathsRespectXDG() {
        let fakeHome = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ConfigPaths.standard(environment: [:], home: fakeHome).directory.path, "/Users/someone/.config/rune")
        XCTAssertEqual(ConfigPaths.standard(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: fakeHome).directory.path, "/tmp/xdg/rune")
        XCTAssertEqual(ConfigPaths.standard(environment: ["XDG_CONFIG_HOME": "relative"], home: fakeHome).directory.path, "/Users/someone/.config/rune")
    }

    // MARK: - deepMerge

    func testDeepMergeMergesNestedObjects() {
        let merged = ConfigLoader.deepMerge(["a": 1, "n": ["x": 1, "y": 2]], ["n": ["y": 3], "b": 2])
        XCTAssertEqual(merged["a"] as? Int, 1)
        XCTAssertEqual(merged["b"] as? Int, 2)
        XCTAssertEqual((merged["n"] as? [String: Int])?["x"], 1)
        XCTAssertEqual((merged["n"] as? [String: Int])?["y"], 3)
    }
}
