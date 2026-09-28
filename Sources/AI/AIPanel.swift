import RuneKit
import SwiftUI

/// Card above the input editor: the AI's streamed answer and a suggested command with
/// Run / Edit / Cancel, or onboarding when AI isn't set up yet.
struct AIPanel: View {
    @ObservedObject var conversation: AIConversation
    @ObservedObject var service = AIService.shared
    let palette: ChromePalette
    let fontSize: CGFloat
    let horizontalPadding: CGFloat
    var onRun: (String) -> Void
    var onEdit: (String) -> Void
    var onPullModel: (String) -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        if conversation.isCollapsed {
            collapsedBar
        } else {
            expandedCard
        }
    }

    /// One line: the latest question, with Show / close. Keeps the conversation for follow-ups.
    private var collapsedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: fontSize - 3, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.accent))
            Text(conversation.prompt)
                .font(.system(size: fontSize - 2))
                .foregroundColor(Color(nsColor: palette.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            if conversation.isActive {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            Text("⌘↵ follow up")
                .font(.system(size: fontSize - 3))
                .foregroundColor(Color(nsColor: palette.hint))
            Button("Show") { conversation.expand() }
                .buttonStyle(.plain)
                .font(.system(size: fontSize - 2, weight: .medium))
                .foregroundColor(Color(nsColor: palette.accent))
            Button { conversation.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundColor(Color(nsColor: palette.hint))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.surface1))
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: palette.outline)).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { conversation.expand() }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch conversation.state {
            case .setup:
                SetupBody(service: service, palette: palette, onPullModel: onPullModel, onOpenSettings: onOpenSettings)
            case .failed(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(nsColor: palette.error))
                    Text(message).foregroundColor(Color(nsColor: palette.text))
                    Spacer()
                    Button("Retry") { service.refresh() }.buttonStyle(.plain).foregroundColor(Color(nsColor: palette.accent))
                    Button("AI settings") { onOpenSettings() }.buttonStyle(.plain).foregroundColor(Color(nsColor: palette.accent))
                }
                .font(.system(size: fontSize - 1))
            default:
                answer
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.surface1))
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: palette.outline)).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: fontSize - 2, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.accent))
            Text(conversation.prompt.isEmpty ? "Ask AI" : conversation.prompt)
                .font(.system(size: fontSize - 1, weight: .medium))
                .foregroundColor(Color(nsColor: palette.text))
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let label = conversation.contextLabel, conversation.state != .setup {
                Label(label, systemImage: "rectangle.stack")
                    .font(.system(size: fontSize - 3))
                    .foregroundColor(Color(nsColor: palette.hint))
                    .lineLimit(1)
                    .help("Sent to the model as context")
            }
            if !conversation.model.isEmpty, conversation.state != .setup {
                Text(conversation.model)
                    .font(.system(size: fontSize - 3, design: .monospaced))
                    .foregroundColor(Color(nsColor: palette.hint))
            }
            if conversation.isActive {
                Text("esc to stop").font(.system(size: fontSize - 3)).foregroundColor(Color(nsColor: palette.hint))
            }
            Button { conversation.dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundColor(Color(nsColor: palette.hint))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (esc)")
        }
    }

    @ViewBuilder
    private var answer: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !conversation.earlier.isEmpty {
                        EarlierTurns(turns: conversation.earlier, palette: palette, fontSize: fontSize)
                    }
                    if conversation.state == .waiting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(conversation.isThinking ? "Thinking…" : "Asking \(conversation.model)…")
                                .font(.system(size: fontSize - 1))
                                .foregroundColor(Color(nsColor: palette.secondary))
                        }
                    }
                    ForEach(Array(conversation.segments.enumerated()), id: \.offset) { _, segment in
                        segmentView(segment)
                    }
                    if conversation.state == .streaming {
                        ProgressView().controlSize(.mini)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: conversation.reply) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: AIPrompt.Segment) -> some View {
        switch segment {
        case .text(let text):
            Text(markdown(text))
                .font(.system(size: fontSize - 0.5))
                .foregroundColor(Color(nsColor: palette.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .command(let command, let complete):
            CommandCard(command: command, palette: palette, fontSize: fontSize,
                        enabled: complete && conversation.state != .waiting,
                        onRun: { onRun(command) }, onEdit: { onEdit(command) })
        case .code(let language, let code, _):
            CodeBox(language: language, code: code, palette: palette, fontSize: fontSize)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// Earlier questions in this conversation, collapsed to one line each.
private struct EarlierTurns: View {
    let turns: [AIConversation.Exchange]
    let palette: ChromePalette
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(turns) { turn in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                    Text(turn.prompt).lineLimit(1).truncationMode(.tail)
                }
                .font(.system(size: fontSize - 2))
                .foregroundColor(Color(nsColor: palette.hint))
                .help(turn.reply)
            }
        }
        .padding(.bottom, 2)
    }
}

/// Non-shell code: shown and copyable, never runnable.
private struct CodeBox: View {
    let language: String
    let code: String
    let palette: ChromePalette
    let fontSize: CGFloat
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language).font(.system(size: fontSize - 3, design: .monospaced)).foregroundColor(Color(nsColor: palette.hint))
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.plain)
                .font(.system(size: fontSize - 3))
                .foregroundColor(Color(nsColor: palette.accent))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Text(code)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundColor(Color(nsColor: palette.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: palette.background)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(nsColor: palette.outline), lineWidth: 1))
    }
}

/// The suggested command. It never runs without the user pressing Run.
private struct CommandCard: View {
    let command: String
    let palette: ChromePalette
    let fontSize: CGFloat
    let enabled: Bool
    let onRun: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(command)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(Color(nsColor: palette.text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: palette.background)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(nsColor: palette.outline), lineWidth: 1))
            HStack(spacing: 8) {
                PanelButton(title: "Run", systemImage: "play.fill", prominent: true, palette: palette, action: onRun)
                    .disabled(!enabled)
                PanelButton(title: "Edit", systemImage: "pencil", prominent: false, palette: palette, action: onEdit)
                    .disabled(!enabled)
                Spacer()
                Text("Review before running")
                    .font(.system(size: fontSize - 3))
                    .foregroundColor(Color(nsColor: palette.hint))
            }
            .opacity(enabled ? 1 : 0.6)
        }
    }
}

private struct PanelButton: View {
    let title: String
    let systemImage: String?
    let prominent: Bool
    let palette: ChromePalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(prominent ? .white : Color(nsColor: palette.text))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(prominent ? Color(nsColor: palette.accent).opacity(hovering ? 0.85 : 1)
                                    : Color(nsColor: hovering ? palette.surface3 : palette.surface2))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What to show when AI isn't usable yet. Never downloads or installs anything itself.
private struct SetupBody: View {
    @ObservedObject var service: AIService
    let palette: ChromePalette
    let onPullModel: (String) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if service.isChecking && !service.hasChecked {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for Ollama on this Mac…") }
            } else {
                switch service.status {
                case .notInstalled:
                    line("AI features run on your own Mac with Ollama, which isn't installed.")
                    HStack(spacing: 8) {
                        PanelButton(title: "Download Ollama", systemImage: "arrow.down.circle", prominent: true, palette: palette) { service.openDownloadPage() }
                        PanelButton(title: "Check again", systemImage: nil, prominent: false, palette: palette) { service.refresh() }
                    }
                case .installedNotRunning(let models):
                    line(models.isEmpty ? "Ollama is installed but not running." : "Ollama is installed but not running. Models on this Mac: \(models.joined(separator: ", ")).")
                    HStack(spacing: 8) {
                        PanelButton(title: "Start Ollama", systemImage: "play.fill", prominent: true, palette: palette) { service.startOllama() }
                        PanelButton(title: "Check again", systemImage: nil, prominent: false, palette: palette) { service.refresh() }
                    }
                case .noModels:
                    line("Ollama is running but has no models yet. A small, fast coding model works well for terminal help.")
                    HStack(spacing: 8) {
                        PanelButton(title: "Pull \(ModelSelection.suggestedModel)", systemImage: "arrow.down", prominent: true, palette: palette) {
                            onPullModel(ModelSelection.suggestedModel)
                        }
                        PanelButton(title: "Check again", systemImage: nil, prominent: false, palette: palette) { service.refresh() }
                    }
                case .unreachable(let url):
                    line("Can't reach the Ollama server at \(url).")
                    HStack(spacing: 8) {
                        PanelButton(title: "AI settings", systemImage: nil, prominent: true, palette: palette, action: onOpenSettings)
                        PanelButton(title: "Retry", systemImage: nil, prominent: false, palette: palette) { service.refresh() }
                    }
                case .ready:
                    line("Ready. Press ⌘↵ again to send.")
                }
            }
        }
        .font(.system(size: 12))
        .foregroundColor(Color(nsColor: palette.text))
    }

    private func line(_ text: String) -> some View {
        Text(text).foregroundColor(Color(nsColor: palette.secondary)).fixedSize(horizontal: false, vertical: true)
    }
}
