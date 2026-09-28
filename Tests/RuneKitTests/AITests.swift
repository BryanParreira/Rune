import XCTest
@testable import RuneKit

final class OllamaEndpointTests: XCTestCase {
    func testResolutionOrder() {
        XCTAssertEqual(OllamaEndpoint.resolve(configValue: nil, environment: [:]).url.absoluteString, "http://localhost:11434")
        XCTAssertEqual(OllamaEndpoint.resolve(configValue: nil, environment: [:]).source, .defaultLocal)

        let env = OllamaEndpoint.resolve(configValue: nil, environment: ["OLLAMA_HOST": "127.0.0.1:9000"])
        XCTAssertEqual(env.url.absoluteString, "http://127.0.0.1:9000")
        XCTAssertEqual(env.source, .environment)

        let cfg = OllamaEndpoint.resolve(configValue: "http://studio.local:11434", environment: ["OLLAMA_HOST": "x"])
        XCTAssertEqual(cfg.url.absoluteString, "http://studio.local:11434")
        XCTAssertEqual(cfg.source, .config)
        XCTAssertFalse(cfg.isLocal)
    }

    func testNormalization() {
        XCTAssertEqual(OllamaEndpoint.normalize("0.0.0.0")?.absoluteString, "http://localhost:11434")
        XCTAssertEqual(OllamaEndpoint.normalize("0.0.0.0:8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(OllamaEndpoint.normalize("gpu-box")?.absoluteString, "http://gpu-box:11434")
        XCTAssertEqual(OllamaEndpoint.normalize("https://ai.example.com")?.absoluteString, "https://ai.example.com")
        XCTAssertEqual(OllamaEndpoint.normalize("http://localhost:11434/")?.absoluteString, "http://localhost:11434")
        XCTAssertNil(OllamaEndpoint.normalize("  "))
        XCTAssertNil(OllamaEndpoint.normalize("ftp://x"))
    }

    func testEmptyConfigFallsThrough() {
        XCTAssertEqual(OllamaEndpoint.resolve(configValue: "", environment: [:]).source, .defaultLocal)
    }

    func testLocalDetection() {
        XCTAssertTrue(OllamaEndpoint.resolve(configValue: "127.0.0.1", environment: [:]).isLocal)
        XCTAssertTrue(OllamaEndpoint.resolve(configValue: nil, environment: [:]).isLocal)
        XCTAssertFalse(OllamaEndpoint.resolve(configValue: "10.0.0.5", environment: [:]).isLocal)
    }
}

final class OllamaDetectorTests: XCTestCase {
    struct Unreachable: Error {}
    private let local = OllamaEndpoint.resolve(configValue: nil, environment: [:])

    private func probe(models: [OllamaModel]? , installed: Bool, disk: [String] = []) -> OllamaProbe {
        OllamaProbe(
            fetchModels: { _ in if let models { return models } else { throw Unreachable() } },
            isInstalled: { installed },
            modelsOnDisk: { disk }
        )
    }

    func testRunningWithModels() async {
        let status = await OllamaDetector.detect(endpoint: local, probe: probe(models: [OllamaModel(name: "b:1"), OllamaModel(name: "a:1")], installed: true))
        XCTAssertEqual(status.models.map(\.name), ["a:1", "b:1"])
    }

    func testRunningWithoutModels() async {
        let status = await OllamaDetector.detect(endpoint: local, probe: probe(models: [], installed: true))
        XCTAssertEqual(status, .noModels)
    }

    func testInstalledNotRunningListsDiskModels() async {
        let status = await OllamaDetector.detect(endpoint: local, probe: probe(models: nil, installed: true, disk: ["llama3:latest"]))
        XCTAssertEqual(status, .installedNotRunning(models: ["llama3:latest"]))
    }

    func testNotInstalled() async {
        let status = await OllamaDetector.detect(endpoint: local, probe: probe(models: nil, installed: false))
        XCTAssertEqual(status, .notInstalled)
    }

    func testRemoteUnreachable() async {
        let remote = OllamaEndpoint.resolve(configValue: "http://gpu-box:11434", environment: [:])
        let status = await OllamaDetector.detect(endpoint: remote, probe: probe(models: nil, installed: true))
        XCTAssertEqual(status, .unreachable("http://gpu-box:11434"))
    }

    func testInstallDetection() {
        let exists: (String) -> Bool = { $0 == "/opt/tools/ollama" }
        XCTAssertTrue(OllamaDetector.isInstalled(home: "/Users/x", path: "/usr/bin:/opt/tools", fileExists: exists))
        XCTAssertFalse(OllamaDetector.isInstalled(home: "/Users/x", path: "/usr/bin", fileExists: exists))
        XCTAssertTrue(OllamaDetector.isInstalled(home: "/Users/x", path: "", fileExists: { $0 == "/Users/x/Applications/Ollama.app" }))
    }

    func testModelsOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rune-ollama-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for path in ["manifests/registry.ollama.ai/library/llama3/latest",
                     "manifests/registry.ollama.ai/library/qwen2.5-coder/3b",
                     "manifests/registry.ollama.ai/someone/custom/v1",
                     "manifests/hf.co/org/model/q4"] {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data("{}".utf8))
        }
        let names = OllamaDetector.modelsOnDisk(environment: ["OLLAMA_MODELS": root.path], home: "/nonexistent").sorted()
        XCTAssertEqual(names, ["hf.co/org/model:q4", "llama3:latest", "qwen2.5-coder:3b", "someone/custom:v1"])
    }
}

final class ModelSelectionTests: XCTestCase {
    func testPreferredKept() {
        XCTAssertEqual(ModelSelection.resolve(preferred: "b:1", installed: ["a:1", "b:1"]), .init(model: "b:1", fellBack: false))
    }

    func testLatestTagMatches() {
        XCTAssertEqual(ModelSelection.resolve(preferred: "llama3", installed: ["llama3:latest"]), .init(model: "llama3:latest", fellBack: false))
    }

    func testDeletedModelFallsBack() {
        XCTAssertEqual(ModelSelection.resolve(preferred: "gone:1", installed: ["a:1", "b:1"]), .init(model: "a:1", fellBack: true))
    }

    func testNoPreferenceUsesFirstWithoutWarning() {
        XCTAssertEqual(ModelSelection.resolve(preferred: nil, installed: ["a:1"]), .init(model: "a:1", fellBack: false))
    }

    func testNothingInstalled() {
        XCTAssertEqual(ModelSelection.resolve(preferred: "x", installed: []), .init(model: nil, fellBack: false))
    }
}

final class OllamaClientParsingTests: XCTestCase {
    func testParseTags() throws {
        let json = #"{"models":[{"name":"gemma4:e2b","size":7162405886,"details":{"parameter_size":"5.1B"},"capabilities":["completion","thinking"]}]}"#
        let models = try OllamaClient.parseTags(Data(json.utf8))
        XCTAssertEqual(models, [OllamaModel(name: "gemma4:e2b", sizeBytes: 7162405886, parameterSize: "5.1B", capabilities: ["completion", "thinking"])])
        XCTAssertTrue(models[0].supportsThinking)
    }

    func testParseChatLines() throws {
        XCTAssertEqual(try OllamaClient.parseChatLine(#"{"message":{"role":"assistant","content":"Hel"},"done":false}"#), [.content("Hel")])
        XCTAssertEqual(try OllamaClient.parseChatLine(#"{"message":{"role":"assistant","content":"","thinking":"hmm"},"done":false}"#), [.thinking("hmm")])
        XCTAssertEqual(try OllamaClient.parseChatLine(#"{"message":{"role":"assistant","content":""},"done":true}"#), [.done])
        XCTAssertEqual(try OllamaClient.parseChatLine(""), [])
        XCTAssertThrowsError(try OllamaClient.parseChatLine(#"{"error":"model not found"}"#))
    }

    func testChatBody() throws {
        let body = OllamaClient.chatBody(model: "m", messages: [.init(role: "user", content: "hi")], disableThinking: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "m")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["think"] as? Bool, false)
        let noThink = try XCTUnwrap(JSONSerialization.jsonObject(with: OllamaClient.chatBody(model: "m", messages: [], disableThinking: false)) as? [String: Any])
        XCTAssertNil(noThink["think"])
    }
}

final class AIPromptTests: XCTestCase {
    func testExtractCommand() {
        XCTAssertEqual(AIPrompt.extractCommand(from: "Use this:\n```sh\nls -la\n```\nDone."), "ls -la")
        XCTAssertEqual(AIPrompt.extractCommand(from: "```bash\n$ brew install jq\n```"), "brew install jq")
        XCTAssertEqual(AIPrompt.extractCommand(from: "```\nfind . -name '*.swift' |\n  wc -l\n```"), "find . -name '*.swift' |\n  wc -l")
        XCTAssertNil(AIPrompt.extractCommand(from: "```python\nprint(1)\n```"))
        XCTAssertNil(AIPrompt.extractCommand(from: "no code here"))
        XCTAssertNil(AIPrompt.extractCommand(from: "```sh\nstill streaming"))
    }

    func testMessagesIncludeContextAndTruncate() {
        let long = String(repeating: "x", count: AIPrompt.maxOutputCharacters + 500) + "END"
        let ctx = AIContext(request: "why?", cwd: "/tmp", osVersion: "macOS 15", shell: "zsh",
                            blockCommand: "make", blockOutput: long, blockExitCode: 2)
        let messages = AIPrompt.messages(for: ctx)
        XCTAssertEqual(messages.map(\.role), ["system", "user"])
        let user = messages[1].content
        XCTAssertTrue(user.contains("Working directory: /tmp"))
        XCTAssertTrue(user.contains("Previous command: make (exit code 2)"))
        XCTAssertTrue(user.contains("…(truncated)…"))
        XCTAssertTrue(user.contains("END"))
        XCTAssertTrue(user.hasSuffix("Request: why?"))
    }

    func testMessagesWithoutBlock() {
        let user = AIPrompt.messages(for: AIContext(request: "list files", cwd: "~", osVersion: "macOS", shell: "zsh"))[1].content
        XCTAssertFalse(user.contains("Previous command"))
    }

    func testAIConfigKeys() {
        var warnings: [String] = []
        let c = RuneConfig(dictionary: ["aiModel": "llama3", "ollamaEndpoint": "http://x", "aiIncludeBlockContext": false], warnings: &warnings)
        XCTAssertEqual(c.aiModel, "llama3")
        XCTAssertEqual(c.ollamaEndpoint, "http://x")
        XCTAssertFalse(c.aiIncludeBlockContext)
        XCTAssertTrue(c.aiEnabled, "AI defaults to on")
        XCTAssertEqual(warnings, [])
        XCTAssertFalse(RuneConfig(dictionary: ["aiEnabled": false], warnings: &warnings).aiEnabled)
    }
}
