import AppKit
import Combine
import RuneKit

/// App-wide view of the local AI: where Ollama is, whether it's running, which models are
/// installed on this machine, and which one the user picked.
final class AIService: ObservableObject {
    static let shared = AIService()

    @Published private(set) var endpoint = OllamaEndpoint.resolve(configValue: nil, environment: ProcessInfo.processInfo.environment)
    @Published private(set) var status: OllamaStatus = .notInstalled
    @Published private(set) var isChecking = false
    @Published private(set) var hasChecked = false
    /// The model requests will use (the user's choice, or a fallback).
    @Published private(set) var activeModel: String?
    /// Shown when the chosen model disappeared and another was picked.
    @Published private(set) var fallbackNotice: String?
    /// The user's master switch. When off, nothing is ever sent to Ollama.
    @Published private(set) var isEnabled = true

    private var preferredModel: String?
    private var cancellables: Set<AnyCancellable> = []
    private var startPoll: Timer?

    private init() {}

    /// Starts following config changes and checks Ollama once.
    func start(store: ConfigStore) {
        store.$snapshot
            .map { ($0.config.aiEnabled, $0.config.ollamaEndpoint, $0.config.aiModel) }
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled, endpointValue, model in
                guard let self else { return }
                let wasEnabled = self.isEnabled
                self.isEnabled = enabled
                guard enabled else {
                    // Forget everything so no UI offers AI.
                    self.status = .notInstalled
                    self.activeModel = nil
                    self.fallbackNotice = nil
                    self.hasChecked = false
                    return
                }
                if !wasEnabled { self.hasChecked = false }
                let newEndpoint = OllamaEndpoint.resolve(configValue: endpointValue, environment: ProcessInfo.processInfo.environment)
                let endpointChanged = newEndpoint != self.endpoint
                self.endpoint = newEndpoint
                self.preferredModel = model
                if endpointChanged || !self.hasChecked {
                    self.refresh()
                } else {
                    self.resolveModel()
                }
            }
            .store(in: &cancellables)
    }

    var client: OllamaClient { OllamaClient(baseURL: endpoint.url) }

    var isReady: Bool { isEnabled && activeModel != nil && !status.models.isEmpty }

    var activeModelInfo: OllamaModel? {
        status.models.first { $0.name == activeModel }
    }

    /// Re-checks the machine: server, installed app/CLI, and models.
    func refresh(completion: (() -> Void)? = nil) {
        guard isEnabled else { completion?(); return }
        isChecking = true
        let endpoint = endpoint
        let client = client
        let home = NSHomeDirectory()
        let environment = ProcessInfo.processInfo.environment
        let path = [environment["PATH"] ?? "", CommandCatalog.shared.shellPath ?? ""].joined(separator: ":")
        let probe = OllamaProbe(
            fetchModels: { _ in try await client.listModels() },
            isInstalled: { OllamaDetector.isInstalled(home: home, path: path) },
            modelsOnDisk: { OllamaDetector.modelsOnDisk(environment: environment, home: home) }
        )
        Task {
            let status = await OllamaDetector.detect(endpoint: endpoint, probe: probe)
            await MainActor.run {
                self.status = status
                self.isChecking = false
                self.hasChecked = true
                self.resolveModel()
                completion?()
            }
        }
    }

    private func resolveModel() {
        let installed = status.models.map(\.name)
        let result = ModelSelection.resolve(preferred: preferredModel, installed: installed)
        activeModel = result.model
        if result.fellBack, let preferred = preferredModel, let model = result.model {
            fallbackNotice = "“\(preferred)” is no longer installed, so Rune is using “\(model)”."
        } else {
            fallbackNotice = nil
        }
    }

    /// Remembers the user's model choice in their config.
    func select(model: String) {
        ConfigStore.current?.write(key: "aiModel", value: model)
    }

    // MARK: Onboarding actions (never installs anything by itself)

    func openDownloadPage() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launches Ollama.app if present, otherwise `ollama serve` from the CLI, then re-checks.
    func startOllama() {
        let fm = FileManager.default
        let apps = ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
        if let app = apps.first(where: { fm.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration())
        } else {
            let path = [ProcessInfo.processInfo.environment["PATH"] ?? "", CommandCatalog.shared.shellPath ?? ""].joined(separator: ":")
            if let binary = path.split(separator: ":").map({ String($0) + "/ollama" }).first(where: { fm.isExecutableFile(atPath: $0) }) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["serve"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
        }
        // Poll for up to ~15 s while the server comes up.
        var attempts = 0
        startPoll?.invalidate()
        startPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            attempts += 1
            self?.refresh {
                guard let self else { return }
                if !self.status.models.isEmpty || self.status == .noModels || attempts >= 10 { timer.invalidate() }
            }
        }
    }
}

extension OllamaModel {
    var displaySize: String? {
        guard let sizeBytes else { return parameterSize }
        let gb = Double(sizeBytes) / 1_000_000_000
        let size = gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1000)
        return [parameterSize, size].compactMap { $0 }.joined(separator: " · ")
    }
}
