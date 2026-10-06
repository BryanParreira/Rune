import AppKit
import RuneKit
import SwiftUI

/// Runs a command again and again (every few seconds, or when files in its folder change)
/// in the background, showing its latest output with the lines that changed marked. The
/// terminal's scrollback isn't filled with repeats.
final class WatchTab: TabContent {
    let id = UUID()
    private let model: WatchModel
    private let host: NSHostingView<WatchView>

    var title: String {
        let command = model.command.components(separatedBy: .newlines).first ?? model.command
        return "Watch · " + (command.count > 20 ? String(command.prefix(19)) + "…" : command)
    }
    var runningProgram: String? { model.running ? model.command : nil }
    var contentView: NSView { host }

    init(command: String, directory: String, shell: String, path: String?, snapshot: ConfigSnapshot) {
        model = WatchModel(command: command, directory: directory, shell: shell, path: path, snapshot: snapshot)
        host = NSHostingView(rootView: WatchView(model: model))
        host.safeAreaRegions = []
        // Fills the pane; its content never sets a minimum size that would grow the window.
        host.sizingOptions = []
        model.start()
    }

    func focus() {
        host.window?.makeFirstResponder(host)
    }

    func apply(_ snapshot: ConfigSnapshot) { model.apply(snapshot) }
    func closeContent() { model.stop() }
}

final class WatchModel: ObservableObject {
    enum Trigger: Hashable {
        case every(TimeInterval)
        case fileChanges

        var label: String {
            switch self {
            case .every(let seconds): return seconds < 60 ? "every \(Int(seconds))s" : "every \(Int(seconds / 60)) min"
            case .fileChanges: return "when files change"
            }
        }

        static let choices: [Trigger] = [.every(2), .every(5), .every(10), .every(30), .every(60), .fileChanges]
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        let text: String
        let changed: Bool
    }

    let command: String
    let directory: String
    private let shell: String
    private let path: String?

    @Published var trigger: Trigger = .every(2) {
        didSet { if trigger != oldValue { schedule() } }
    }
    @Published var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused {
                cancelSchedule()
            } else {
                schedule()
                runNow()
            }
        }
    }
    @Published var ignoreNumbers = false
    @Published var notifyOnChange = false
    @Published private(set) var lines: [Line] = []
    @Published private(set) var runs = 0
    @Published private(set) var changedCount = 0
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastDuration: TimeInterval = 0
    @Published private(set) var lastChangeAt: Date?
    @Published private(set) var exitCode: Int32?
    @Published private(set) var running = false
    @Published private(set) var palette: ChromePalette
    @Published private(set) var font: NSFont

    private var previous: [String]?
    private var timer: Timer?
    private var watcher: TreeWatcher?
    private var process: Process?
    private var stopped = false

    /// Output kept from each run (the end, if it's longer).
    static let maxLines = 5_000
    private static let maxBytes = 4 << 20

    init(command: String, directory: String, shell: String, path: String?, snapshot: ConfigSnapshot) {
        self.command = command
        self.directory = directory
        self.shell = shell
        self.path = path
        palette = ChromePalette(theme: snapshot.theme)
        font = snapshot.font
    }

    func apply(_ snapshot: ConfigSnapshot) {
        palette = ChromePalette(theme: snapshot.theme)
        font = snapshot.font
    }

    func start() {
        schedule()
        runNow()
    }

    func stop() {
        stopped = true
        cancelSchedule()
        if let process, process.isRunning { process.terminate() }
    }

    private func cancelSchedule() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
    }

    private func schedule() {
        cancelSchedule()
        guard !paused, !stopped else { return }
        switch trigger {
        case .every(let seconds):
            // Counted from the end of a run, so a slow command never piles up.
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, !self.running, let last = self.lastRunAt else { return }
                if Date().timeIntervalSince(last) - self.lastDuration >= seconds { self.runNow() }
            }
        case .fileChanges:
            let watcher = TreeWatcher { [weak self] in self?.runNow() }
            watcher.watch(URL(fileURLWithPath: directory, isDirectory: true))
            self.watcher = watcher
        }
    }

    /// Runs the command unless it's still running from last time.
    func runNow() {
        guard !running, !stopped else { return }
        running = true
        let started = Date()
        lastRunAt = started
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        environment["TERM"] = "dumb"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        self.process = process
        do {
            try process.run()
        } catch {
            finish(output: "Couldn't start \(shell): \(error.localizedDescription)", status: 127, started: started)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Keep only the end while reading: a command that prints without stopping would
            // otherwise grow memory until macOS kills Rune.
            var data = Data()
            let handle = pipe.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                data.append(chunk)
                if data.count > Self.maxBytes * 2 { data = Data(data.suffix(Self.maxBytes)) }
            }
            process.waitUntilExit()
            if data.count > Self.maxBytes { data = Data(data.suffix(Self.maxBytes)) }
            let text = ANSIText.plain(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                self?.finish(output: text, status: process.terminationStatus, started: started)
            }
        }
    }

    private func finish(output: String, status: Int32, started: Date) {
        running = false
        process = nil
        guard !stopped else { return }
        var all = output.components(separatedBy: "\n")
        while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
        let new = Array(all.suffix(Self.maxLines))
        let changed = previous.map { OutputDiff.changedLines(old: $0, new: new, ignoreNumbers: ignoreNumbers) } ?? IndexSet()
        lines = new.enumerated().map { Line(id: $0.offset, text: $0.element, changed: changed.contains($0.offset)) }
        let exitChanged = runs > 0 && status != exitCode
        if previous != nil, !changed.isEmpty || exitChanged {
            lastChangeAt = Date()
            if notifyOnChange, !NSApp.isActive {
                CommandNotifier.shared.post(title: "Output changed", subtitle: exitChanged ? "exit \(status)" : "\(changed.count) line\(changed.count == 1 ? "" : "s") changed",
                                            body: command)
            }
        }
        changedCount = changed.count
        previous = new
        exitCode = status
        lastDuration = Date().timeIntervalSince(started)
        runs += 1
    }
}

struct WatchView: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            header
            if model.lines.isEmpty {
                Text(model.runs == 0 ? "first run…" : "no output")
                    .font(.hand(24))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                output
            }
        }
        .background(Color(nsColor: p.background))
    }

    private var header: some View {
        let p = model.palette
        return HStack(spacing: 12) {
            Image(systemName: model.paused ? "eye.slash" : "eye")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: model.paused ? p.hint : p.accent))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: p.surface1)))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.command)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: p.text))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(status(now: context.date))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: model.exitCode.map { $0 != 0 } == true ? p.error : p.hint))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            if model.changedCount > 0 {
                MetaChip(text: "\(model.changedCount) changed", palette: p, color: p.ansiYellow)
            }
            Menu(model.trigger.label) {
                ForEach(WatchModel.Trigger.choices, id: \.self) { choice in
                    Button(choice.label) { model.trigger = choice }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.system(size: 12))
            .help("When to run it again")
            Toggle("Ignore numbers", isOn: $model.ignoreNumbers)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .foregroundColor(Color(nsColor: p.secondary))
                .help("Don't mark lines that only changed in numbers (timings, counts, dates)")
            Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1, height: 18).padding(.horizontal, 2)
            IconAction(symbol: model.notifyOnChange ? "bell.fill" : "bell", help: "Notify me when the output changes while I'm in another app",
                       palette: p, isOn: model.notifyOnChange) { model.notifyOnChange.toggle() }
            IconAction(symbol: "arrow.clockwise", help: "Run now", palette: p) { model.runNow() }
            IconAction(symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause", palette: p) {
                model.paused.toggle()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
    }

    private func status(now: Date) -> String {
        var parts: [String] = []
        if model.running {
            parts.append("running…")
        } else if let last = model.lastRunAt {
            parts.append("ran \(Self.ago(now.timeIntervalSince(last))) ago")
        }
        parts.append("\(model.runs) run\(model.runs == 1 ? "" : "s")")
        if let code = model.exitCode, code != 0 { parts.append("exit \(code)") }
        if model.runs > 0 { parts.append(BlockOverlayView.format(duration: model.lastDuration)) }
        if let change = model.lastChangeAt { parts.append("last change \(Self.ago(now.timeIntervalSince(change))) ago") }
        if model.paused { parts.append("paused") }
        return parts.joined(separator: "  ·  ") + "  ·  " + TabTitle.abbreviate(path: model.directory, home: NSHomeDirectory())
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    private var output: some View {
        let p = model.palette
        let font = Font(model.font)
        return GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text.replacingOccurrences(of: "\t", with: "    "))
                            .font(font)
                            .foregroundColor(Color(nsColor: p.text))
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(.horizontal, 18)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Lines that changed since the last run, marked like a highlighter pen.
                            .background(line.changed ? Color(nsColor: p.highlight) : .clear)
                    }
                }
                .padding(.vertical, 12)
                .frame(minWidth: viewport.size.width, alignment: .leading)
            }
            // Short output reads from the top; a long log opens at its end.
            .defaultScrollAnchor(model.lines.count > 60 ? .bottom : .top)
        }
    }
}
