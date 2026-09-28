import Foundation

/// Watches a set of directories (non-recursively) and calls `onChange` on the main queue,
/// debounced. Watching the directory rather than the file catches editors that save by
/// writing a temp file and renaming it over the original.
public final class DirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let onChange: () -> Void

    public init(debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func watch(_ directories: [URL]) {
        stop()
        for dir in Set(directories.map(\.standardizedFileURL)) {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend, .attrib],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.schedule() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    public func stop() {
        pending?.cancel()
        pending = nil
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
