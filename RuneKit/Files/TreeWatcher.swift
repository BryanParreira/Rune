import CoreServices
import Foundation

/// Watches a folder and everything inside it (FSEvents) and calls `onChange` on the main
/// queue, debounced. Changes inside version-control and dependency/build folders are ignored,
/// so a build writing its outputs doesn't retrigger itself.
public final class TreeWatcher {
    public static let ignoredComponents: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "target", "dist", ".next", "__pycache__", ".venv", ".DS_Store"]

    private var stream: FSEventStreamRef?
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    public init(debounce: TimeInterval = 0.4, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func watch(_ directory: URL) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<TreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { !TreeWatcher.isIgnored($0) }) {
                watcher.schedule()
            }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Whether a changed path is inside an ignored folder (or is an ignored file).
    public static func isIgnored(_ path: String) -> Bool {
        path.split(separator: "/").contains { ignoredComponents.contains(String($0)) }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
