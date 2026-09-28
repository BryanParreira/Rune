import AppKit
import Combine
import Sparkle

/// In-app updates via Sparkle. The only network traffic is fetching the release feed
/// (SUFeedURL in Info.plist) and, when the user accepts, the signed update itself.
/// Every update is verified against the EdDSA public key (SUPublicEDKey) before installing.
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private let controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    /// False when this build has no feed configured (e.g. a local debug build).
    let isAvailable: Bool
    @Published private(set) var canCheck = false
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyChecks: Bool {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        var enabled = !feed.isEmpty && !key.isEmpty
        #if DEBUG
        // Debug builds don't update themselves unless explicitly asked to (for testing the flow).
        enabled = enabled && ProcessInfo.processInfo.environment["RUNE_TEST_UPDATES"] == "1"
        #endif
        isAvailable = enabled

        if enabled {
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            self.controller = controller
            automaticallyChecks = controller.updater.automaticallyChecksForUpdates
            canCheck = controller.updater.canCheckForUpdates
            lastChecked = controller.updater.lastUpdateCheckDate
            let updater = controller.updater
            observations = [
                updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                    DispatchQueue.main.async { self?.canCheck = updater.canCheckForUpdates }
                },
                updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                    DispatchQueue.main.async { self?.lastChecked = updater.lastUpdateCheckDate }
                },
                updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] updater, _ in
                    DispatchQueue.main.async {
                        guard let self, self.automaticallyChecks != updater.automaticallyChecksForUpdates else { return }
                        self.automaticallyChecks = updater.automaticallyChecksForUpdates
                    }
                },
            ]
        } else {
            controller = nil
            automaticallyChecks = false
        }
    }

    /// Starts the updater at launch (called from the app delegate).
    func start() {
        _ = controller
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }
}
