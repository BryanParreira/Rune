import AppKit
import RuneKit
import SwiftUI

/// Two runs of a command side by side as a diff of their output: what changed between the
/// test run before and after a fix, the build that broke, the `curl` that started failing.
final class OutputCompareTab: TabContent {
    let id = UUID()
    let runningProgram: String? = nil
    private let model: OutputCompareModel
    private let host: NSHostingView<OutputCompareView>

    var title: String {
        let command = model.new.shortCommand
        return "Compare · " + (command.count > 18 ? String(command.prefix(17)) + "…" : command)
    }
    var contentView: NSView { host }

    init(old: OutputCompareModel.Run, new: OutputCompareModel.Run, snapshot: ConfigSnapshot) {
        model = OutputCompareModel(old: old, new: new, snapshot: snapshot)
        host = NSHostingView(rootView: OutputCompareView(model: model))
        host.safeAreaRegions = []
    }

    func focus() {
        host.window?.makeFirstResponder(host)
    }

    func apply(_ snapshot: ConfigSnapshot) { model.apply(snapshot) }
    func closeContent() {}
}

final class OutputCompareModel: ObservableObject {
    struct Run {
        let command: String
        let output: String
        let startedAt: Date
        let exitCode: Int32?
        let failed: Bool

        var shortCommand: String {
            let first = command.components(separatedBy: .newlines).first ?? command
            return first.count > 40 ? String(first.prefix(39)) + "…" : first
        }
    }

    let old: Run
    let new: Run
    @Published var ignoreNumbers = false {
        didSet { recompute() }
    }
    @Published private(set) var diff: GitDiff?
    @Published private(set) var palette: ChromePalette
    @Published private(set) var font: NSFont
    private var generation = 0

    init(old: Run, new: Run, snapshot: ConfigSnapshot) {
        self.old = old
        self.new = new
        palette = ChromePalette(theme: snapshot.theme)
        font = snapshot.font
        recompute()
    }

    func apply(_ snapshot: ConfigSnapshot) {
        palette = ChromePalette(theme: snapshot.theme)
        font = snapshot.font
    }

    private func recompute() {
        generation += 1
        let current = generation
        let (old, new, ignore) = (old.output, new.output, ignoreNumbers)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let diff = OutputDiff.compare(old: old, new: new, ignoreNumbers: ignore)
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.diff = diff
            }
        }
    }

    /// The changes as a unified diff, for pasting into an issue or a chat.
    func copyDiff() {
        guard let diff else { return }
        var text = "--- \(old.command)\n+++ \(new.command)\n"
        for line in diff.lines {
            switch line.kind {
            case .hunk: text += "@@ \(line.text) @@\n"
            case .added: text += "+" + line.text + "\n"
            case .removed: text += "-" + line.text + "\n"
            case .context: text += " " + line.text + "\n"
            case .note: break
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SecretRedactor.redact(text), forType: .string)
    }
}

struct OutputCompareView: View {
    @ObservedObject var model: OutputCompareModel

    var body: some View {
        let p = model.palette
        VStack(spacing: 0) {
            header
            if let diff = model.diff {
                if diff.lines.isEmpty {
                    VStack(spacing: 6) {
                        Text("same output both times").font(.hand(26)).foregroundColor(Color(nsColor: p.secondary))
                        Text(model.ignoreNumbers ? "Apart from numbers (timings, counts, dates), nothing changed."
                                                 : "Every line matches.")
                            .font(.system(size: 12.5)).foregroundColor(Color(nsColor: p.hint))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DiffLinesView(diff: diff, palette: p, font: model.font)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: p.background))
    }

    private var header: some View {
        let p = model.palette
        return HStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: p.accent))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: p.surface1)))
            VStack(alignment: .leading, spacing: 3) {
                runLine(model.old, sign: "−", color: p.error)
                runLine(model.new, sign: "+", color: p.success)
            }
            Spacer(minLength: 16)
            if let diff = model.diff {
                if diff.added > 0 { MetaChip(text: "+\(diff.added)", palette: p, color: p.success) }
                if diff.removed > 0 { MetaChip(text: "−\(diff.removed)", palette: p, color: p.error) }
                if diff.truncated { MetaChip(text: "last \(OutputDiff.maxLines.formatted()) lines", palette: p, color: p.ansiYellow) }
            }
            Toggle("Ignore numbers", isOn: $model.ignoreNumbers)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .foregroundColor(Color(nsColor: p.secondary))
                .help("Treat lines that only differ in numbers (timings, counts, dates) as unchanged")
            Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1, height: 18).padding(.horizontal, 2)
            IconAction(symbol: "doc.on.doc", help: "Copy the changes as a diff (secrets removed)", palette: p) { model.copyDiff() }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
    }

    private func runLine(_ run: OutputCompareModel.Run, sign: String, color: NSColor) -> some View {
        let p = model.palette
        return HStack(spacing: 8) {
            Text(sign).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(Color(nsColor: color))
            Text(run.shortCommand)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: p.text))
                .lineLimit(1)
            Text(run.startedAt.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: p.hint))
            if run.failed, let code = run.exitCode {
                Text("exit \(code)").font(.system(size: 11, weight: .medium)).foregroundColor(Color(nsColor: p.error))
            }
        }
    }
}
