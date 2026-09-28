import Foundation

/// Where to reach Ollama. Resolution order: config `ollamaEndpoint` → `$OLLAMA_HOST` →
/// http://localhost:11434. Rune never depends on any particular server or machine.
public struct OllamaEndpoint: Equatable, Sendable {
    public let url: URL
    public let source: Source

    public enum Source: Equatable, Sendable {
        case config
        case environment
        case defaultLocal
    }

    public static let defaultURL: URL = {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = 11434
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    /// True when requests stay on this Mac.
    public var isLocal: Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    public static func resolve(configValue: String?, environment: [String: String]) -> OllamaEndpoint {
        if let configValue, let url = normalize(configValue) {
            return OllamaEndpoint(url: url, source: .config)
        }
        if let env = environment["OLLAMA_HOST"], let url = normalize(env) {
            return OllamaEndpoint(url: url, source: .environment)
        }
        return OllamaEndpoint(url: defaultURL, source: .defaultLocal)
    }

    /// Accepts the forms Ollama itself accepts: "host", "host:port", ":port", "http(s)://host[:port]".
    /// A bind-all address (0.0.0.0 / ::) means "this machine" when used as a client address.
    public static func normalize(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let host = components.host ?? ""
        if host.isEmpty || host == "0.0.0.0" || host == "::" || host == "[::]" {
            components.host = "localhost"
        }
        if components.port == nil, scheme == "http" {
            components.port = 11434
        }
        if components.path == "/" { components.path = "" }
        return components.url
    }
}

public struct OllamaModel: Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var sizeBytes: Int64?
    public var parameterSize: String?
    public var capabilities: [String]

    public var id: String { name }
    public var supportsThinking: Bool { capabilities.contains("thinking") }

    public init(name: String, sizeBytes: Int64? = nil, parameterSize: String? = nil, capabilities: [String] = []) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.capabilities = capabilities
    }
}

/// What Rune knows about Ollama on this machine.
public enum OllamaStatus: Equatable, Sendable {
    /// Server reachable and has models.
    case ready([OllamaModel])
    /// Server reachable but no models pulled yet.
    case noModels
    /// Ollama is installed but its server isn't answering. `models` are read from disk.
    case installedNotRunning(models: [String])
    /// No Ollama app or CLI found (and the endpoint doesn't answer).
    case notInstalled
    /// A non-local endpoint was configured and isn't answering.
    case unreachable(String)

    public var models: [OllamaModel] {
        if case .ready(let models) = self { return models }
        return []
    }
}

/// Everything the detector needs from the outside world, injectable for tests.
public struct OllamaProbe: Sendable {
    public var fetchModels: @Sendable (URL) async throws -> [OllamaModel]
    public var isInstalled: @Sendable () -> Bool
    public var modelsOnDisk: @Sendable () -> [String]

    public init(fetchModels: @escaping @Sendable (URL) async throws -> [OllamaModel],
                isInstalled: @escaping @Sendable () -> Bool,
                modelsOnDisk: @escaping @Sendable () -> [String]) {
        self.fetchModels = fetchModels
        self.isInstalled = isInstalled
        self.modelsOnDisk = modelsOnDisk
    }
}

public enum OllamaDetector {
    public static func detect(endpoint: OllamaEndpoint, probe: OllamaProbe) async -> OllamaStatus {
        do {
            let models = try await probe.fetchModels(endpoint.url)
            return models.isEmpty ? .noModels : .ready(models.sorted { $0.name < $1.name })
        } catch {
            if !endpoint.isLocal {
                return .unreachable(endpoint.url.absoluteString)
            }
            if probe.isInstalled() {
                return .installedNotRunning(models: probe.modelsOnDisk().sorted())
            }
            return .notInstalled
        }
    }

    /// Ollama.app in /Applications or ~/Applications, or `ollama` on any of the PATH dirs.
    public static func isInstalled(home: String, path: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        if fileExists("/Applications/Ollama.app") || fileExists(home + "/Applications/Ollama.app") { return true }
        return path.split(separator: ":").contains { fileExists(String($0) + "/ollama") }
    }

    /// Model names from Ollama's manifest store: <models>/manifests/<registry>/<namespace>/<name>/<tag>.
    /// Works while the server is stopped. Honors $OLLAMA_MODELS.
    public static func modelsOnDisk(environment: [String: String], home: String) -> [String] {
        let root = environment["OLLAMA_MODELS"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.ollama/models"
        let manifests = URL(fileURLWithPath: root).appendingPathComponent("manifests")
        let fm = FileManager.default
        var names: [String] = []
        let registries = (try? fm.contentsOfDirectory(atPath: manifests.path)) ?? []
        for registry in registries where !registry.hasPrefix(".") {
            let regURL = manifests.appendingPathComponent(registry)
            for namespace in (try? fm.contentsOfDirectory(atPath: regURL.path)) ?? [] where !namespace.hasPrefix(".") {
                let nsURL = regURL.appendingPathComponent(namespace)
                for model in (try? fm.contentsOfDirectory(atPath: nsURL.path)) ?? [] where !model.hasPrefix(".") {
                    let modelURL = nsURL.appendingPathComponent(model)
                    for tag in (try? fm.contentsOfDirectory(atPath: modelURL.path)) ?? [] where !tag.hasPrefix(".") {
                        var name = namespace == "library" ? model : "\(namespace)/\(model)"
                        if registry != "registry.ollama.ai" { name = "\(registry)/\(name)" }
                        names.append("\(name):\(tag)")
                    }
                }
            }
        }
        return names
    }
}

/// Picks the model to use: the user's choice if it's still installed, else the first one.
public enum ModelSelection {
    public struct Result: Equatable, Sendable {
        public var model: String?
        /// The preferred model was set but is gone; `model` is a fallback.
        public var fellBack: Bool
    }

    public static func resolve(preferred: String?, installed: [String]) -> Result {
        if let preferred, installed.contains(preferred) {
            return Result(model: preferred, fellBack: false)
        }
        // "llama3" should match "llama3:latest".
        if let preferred, !preferred.contains(":"), installed.contains(preferred + ":latest") {
            return Result(model: preferred + ":latest", fellBack: false)
        }
        return Result(model: installed.first, fellBack: preferred != nil && !installed.isEmpty)
    }

    /// Small, capable default to suggest when nothing is installed.
    public static let suggestedModel = "qwen2.5-coder:3b"
}
