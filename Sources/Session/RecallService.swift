import Foundation
import RuneKit

/// Owns the Recall database: records finished commands and answers searches, all on a
/// background queue. Stored at ~/Library/Application Support/Rune/recall.sqlite.
final class RecallService {
    static let shared = RecallService()

    /// Output kept per command: the last this many lines.
    static let maxOutputLines = 2_000
    private static let maxEntries = 50_000

    private let queue = DispatchQueue(label: "dev.rune.recall", qos: .utility)
    private var store: RecallStore?
    private var opened = false

    static var url: URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["RUNE_DEBUG_RECALL_FILE"] { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Rune", isDirectory: true)
            .appendingPathComponent("recall.sqlite")
    }

    /// Test runs share this Mac's files; they only record when pointed at a scratch file.
    private var isAllowed: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RUNE_DEBUG_SCRIPT"] != nil {
            return ProcessInfo.processInfo.environment["RUNE_DEBUG_RECALL_FILE"] != nil
        }
        #endif
        return true
    }

    private init() {}

    /// Call on `queue` only.
    private func openIfNeeded() -> RecallStore? {
        if !opened {
            opened = true
            if isAllowed, let url = Self.url { store = RecallStore(url: url) }
        }
        return store
    }

    /// Saves a finished command. Secrets are removed here, before anything touches the disk.
    func record(command: String, output: String, directory: String, exitCode: Int32?, duration: Double) {
        queue.async { [weak self] in
            guard let store = self?.openIfNeeded() else { return }
            store.add(RecallStore.Entry(date: Date(), directory: directory, command: SecretRedactor.redact(command),
                                        output: SecretRedactor.redact(output), exitCode: exitCode, duration: duration))
        }
    }

    func search(_ query: String, limit: Int = 200, completion: @escaping ([RecallStore.Entry]) -> Void) {
        queue.async { [weak self] in
            let results = self?.openIfNeeded()?.search(query, limit: limit) ?? []
            DispatchQueue.main.async { completion(results) }
        }
    }

    func count(completion: @escaping (Int) -> Void) {
        queue.async { [weak self] in
            let count = self?.openIfNeeded()?.count ?? 0
            DispatchQueue.main.async { completion(count) }
        }
    }

    /// Drops history older than the configured number of days (run at launch).
    func prune(keepingDays days: Double) {
        queue.async { [weak self] in
            self?.openIfNeeded()?.prune(olderThan: Date().addingTimeInterval(-days * 86_400), maxEntries: Self.maxEntries)
        }
    }

    func removeAll(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            self?.openIfNeeded()?.removeAll()
            DispatchQueue.main.async { completion?() }
        }
    }
}
