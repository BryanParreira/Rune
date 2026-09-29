import AppKit
import Combine
import RuneKit
import SwiftUI

/// First-launch guide: asks for the macOS permissions a terminal needs (folder access, optional
/// Full Disk Access), sets up AI and a few preferences. Shown once per Mac, before the first
/// terminal window; reopen it from Rune → Welcome Guide…
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "RuneOnboardingCompletedVersion"
    static let currentVersion = 1

    static var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: completedKey) < currentVersion
    }

    static let size = NSSize(width: 780, height: 520)

    private let model: OnboardingModel
    /// Called once when the guide closes (finished, skipped, or closed with the red button).
    var onClose: (() -> Void)?

    init(store: ConfigStore) {
        model = OnboardingModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: store.snapshot.theme.isLight ? .aqua : .darkAqua)
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Rune"
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        super.init(window: window)
        window.delegate = self
        let host = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in self?.finish() })
        host.safeAreaRegions = []
        window.contentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func finish() {
        markCompleted()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window counts as done; the guide stays available from the menu.
        markCompleted()
        model.stopPolling()
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }

    private func markCompleted() {
        guard !AppDelegate.isAutomatedRun else { return }
        UserDefaults.standard.set(Self.currentVersion, forKey: Self.completedKey)
    }
}

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, permissions, setup
    }

    enum Access: Equatable { case unknown, granted, denied, missing }

    let store: ConfigStore
    @Published var step: Step = .welcome
    /// +1 moving forward, -1 going back; steers the page transition.
    private(set) var direction = 1
    @Published private(set) var folderAccess: [String: Access] = [:]
    @Published private(set) var isRequestingFolders = false
    @Published private(set) var fullDiskAccess = false
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    static let folders = ["Desktop", "Documents", "Downloads"]

    init(store: ConfigStore) {
        self.store = store
        refreshFolderAccess(requesting: false)
        fullDiskAccess = Self.hasFullDiskAccess()
        $step.sink { [weak self] step in
            if step == .permissions { self?.startPolling() } else { self?.stopPolling() }
            if step == .setup { AIService.shared.refresh() }
        }.store(in: &cancellables)
    }

    var config: RuneConfig { store.snapshot.config }
    var palette: ChromePalette { ChromePalette(theme: store.snapshot.theme) }

    func next() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        direction = 1
        step = next
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        direction = -1
        step = previous
    }

    // MARK: Folders

    /// Reading each folder makes macOS show its "Rune would like to access…" prompt once.
    /// Commands you run in Rune inherit these permissions, so granting them now avoids
    /// prompts interrupting you later.
    func requestFolderAccess() {
        isRequestingFolders = true
        DispatchQueue.global(qos: .userInitiated).async {
            let results = Self.checkFolders()
            DispatchQueue.main.async {
                self.folderAccess = results
                self.isRequestingFolders = false
            }
        }
    }

    private func refreshFolderAccess(requesting: Bool) {
        // Without requesting, we can't read the TCC state directly; mark as unknown until asked.
        folderAccess = Dictionary(uniqueKeysWithValues: Self.folders.map { ($0, .unknown) })
    }

    private static func checkFolders() -> [String: Access] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var result: [String: Access] = [:]
        for name in folders {
            let url = home.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                result[name] = .missing
                continue
            }
            result[name] = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil ? .granted : .denied
        }
        return result
    }

    var allFoldersGranted: Bool {
        folderAccess.values.allSatisfy { $0 == .granted || $0 == .missing } && !folderAccess.isEmpty
            && !folderAccess.values.contains(.unknown)
    }

    func openFilesAndFoldersSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    // MARK: Full Disk Access

    /// A protected file only readable with Full Disk Access.
    static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: probe.path)
            && (try? FileHandle(forReadingFrom: probe))?.readData(ofLength: 1) != nil
    }

    func openFullDiskAccessSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let granted = Self.hasFullDiskAccess()
            if self?.fullDiskAccess != granted { self?.fullDiskAccess = granted }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Preferences

    func set(_ key: String, _ value: Any?) {
        store.write(key: key, value: value)
        objectWillChange.send()
    }

}

// MARK: - Views

extension OnboardingModel.Step {
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Access"
        case .setup: return "Setup"
        }
    }

    var caption: String {
        switch self {
        case .welcome: return "What Rune does"
        case .permissions: return "Folders & disk"
        case .setup: return "Input & private AI"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    var body: some View {
        let p = model.palette
        HStack(spacing: 0) {
            StepRail(model: model)
                .frame(width: 236)
            Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    page
                        .id(model.step)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 18 * CGFloat(model.direction))),
                            removal: .opacity.combined(with: .offset(x: -12 * CGFloat(model.direction)))))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .background(
                ZStack {
                    Color(nsColor: p.background)
                    RadialGradient(colors: [Color(nsColor: p.accent).opacity(0.08), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 420)
                }
            )
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: model.step)
        .tint(Color(nsColor: p.accent))
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .setup: SetupStep(model: model)
        }
    }

    private var footer: some View {
        let p = model.palette
        return HStack(spacing: 18) {
            if model.step != .welcome {
                Button { model.back() } label: {
                    Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(nsColor: p.secondary))
            }
            Spacer()
            if model.step != .setup {
                Button("Skip") { onFinish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(nsColor: p.hint))
                    .help("Skip setup. You can reopen this from Rune → Welcome Guide.")
            }
            Button {
                model.step == .setup ? onFinish() : model.next()
            } label: {
                HStack(spacing: 8) {
                    Text(primaryTitle)
                    Image(systemName: model.step == .setup ? "arrow.right" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(nsColor: p.accent.blended(withFraction: 0.12, of: .white) ?? p.accent),
                                                      Color(nsColor: p.accent)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: Color(nsColor: p.accent).opacity(0.25), radius: 8, y: 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "Get Started"
        case .permissions: return "Continue"
        case .setup: return "Start Using Rune"
        }
    }
}

/// Left column: the app, the three steps with progress, and the privacy promise.
private struct StepRail: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rune").font(.system(size: 16, weight: .bold)).foregroundColor(Color(nsColor: p.text))
                    Text(versionText).font(.system(size: 11, weight: .medium)).foregroundColor(Color(nsColor: p.hint))
                }
            }
            .padding(.top, 58)
            .padding(.bottom, 34)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    StepRow(step: step, current: model.step, palette: p)
                }
            }

            Spacer()

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: p.success))
                    .padding(.top, 1)
                Text("No accounts, no telemetry. Your commands and AI chats stay on this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(nsColor: p.hint))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: p.surface1))
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Version \($0)" } ?? "Terminal"
    }
}

private struct StepRow: View {
    let step: OnboardingModel.Step
    let current: OnboardingModel.Step
    let palette: ChromePalette

    var body: some View {
        let p = palette
        let isCurrent = step == current
        let isDone = step.rawValue < current.rawValue
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: isCurrent ? p.accent : (isDone ? p.success.withAlphaComponent(0.16) : p.foreground.withAlphaComponent(0.06))))
                Circle()
                    .stroke(Color(nsColor: isCurrent || isDone ? .clear : p.foreground.withAlphaComponent(0.14)), lineWidth: 1)
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color(nsColor: p.success))
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(isCurrent ? .white : Color(nsColor: p.secondary))
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(Color(nsColor: isCurrent ? p.text : p.secondary))
                Text(step.caption)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: p.hint))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: isCurrent ? p.foreground.withAlphaComponent(0.06) : .clear))
        )
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Step counter, title and subtitle at the top of each page.
private struct Heading: View {
    let step: OnboardingModel.Step
    let title: String
    /// A word in the title marked with the highlighter.
    var highlight: String?
    let subtitle: String
    /// Handwritten note beside the step label.
    var note: String?
    let palette: ChromePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("STEP \(step.rawValue + 1) OF \(OnboardingModel.Step.allCases.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(Color(nsColor: palette.accent))
                if let note {
                    MarginNote(text: note, color: palette.secondary, size: 19)
                }
            }
            titleView
                .font(.serif(36))
                .foregroundColor(Color(nsColor: palette.text))
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundColor(Color(nsColor: palette.secondary))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    @ViewBuilder
    private var titleView: some View {
        if let highlight, let range = title.range(of: highlight) {
            HStack(spacing: 0) {
                Text(String(title[..<range.lowerBound]))
                Text(highlight).highlighterMark(palette.highlight)
                Text(String(title[range.upperBound...]))
            }
        } else {
            Text(title)
        }
    }
}

/// A grouped list of rows, like System Settings.
private struct Card<Content: View>: View {
    let palette: ChromePalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: palette.foreground.withAlphaComponent(0.04))))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.08)), lineWidth: 1))
    }
}

private struct Row<Trailing: View>: View {
    let symbol: String
    let tint: NSColor
    let title: String
    let detail: String
    let palette: ChromePalette
    var divider = true
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(nsColor: tint))
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: tint.withAlphaComponent(0.13))))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color(nsColor: palette.text))
                    Text(detail).font(.system(size: 12)).foregroundColor(Color(nsColor: palette.secondary))
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            if divider {
                Rectangle().fill(Color(nsColor: palette.foreground.withAlphaComponent(0.07))).frame(height: 1).padding(.leading, 62)
            }
        }
    }
}

private struct SmallButton: View {
    let title: String
    let palette: ChromePalette
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(prominent ? .white : Color(nsColor: palette.text))
                .padding(.horizontal, 13)
                .frame(height: 27)
                .background(Capsule().fill(Color(nsColor: prominent ? palette.accent : palette.foreground.withAlphaComponent(0.1))))
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct Done: View {
    let text: String
    let palette: ChromePalette
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(nsColor: palette.success))
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 26) {
            Heading(step: .welcome, title: "A faster, calmer terminal", highlight: "calmer",
                    subtitle: "Rune keeps your shell and adds the parts that make it easier to use. Setup takes under a minute.",
                    note: "no account needed", palette: p)
            Card(palette: p) {
                Row(symbol: "square.stack.3d.up.fill", tint: p.accent, title: "Command blocks",
                    detail: "Each command and its output stay together. Copy, rerun or jump between them with ⌘↑ ⌘↓.",
                    palette: p) { EmptyView() }
                Row(symbol: "text.cursor", tint: p.ansiCyan, title: "A real input editor",
                    detail: "Suggestions from your history, syntax colors and Tab completion, with your zsh setup intact.",
                    palette: p) { EmptyView() }
                Row(symbol: "sparkle", tint: p.ansiYellow, title: "Private AI, when you ask",
                    detail: "Optional local models through Ollama. Only ⌘↵ sends anything to AI.",
                    palette: p, divider: false) { EmptyView() }
            }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 26) {
            Heading(step: .permissions, title: "Give Rune access", highlight: "access",
                    subtitle: "Commands you run use Rune's permissions. Allow access now so macOS doesn't interrupt you mid-command.",
                    note: "you can change these later", palette: p)
            Card(palette: p) {
                Row(symbol: "folder.fill", tint: p.ansiBlue, title: "Desktop, Documents & Downloads",
                    detail: "macOS asks once for each folder.", palette: p) {
                    if model.allFoldersGranted {
                        Done(text: "Allowed", palette: p)
                    } else if model.isRequestingFolders {
                        ProgressView().controlSize(.small)
                    } else if model.folderAccess.values.contains(.denied) {
                        SmallButton(title: "Open Settings", palette: p) { model.openFilesAndFoldersSettings() }
                    } else {
                        SmallButton(title: "Allow", palette: p, prominent: true) { model.requestFolderAccess() }
                    }
                }
                Row(symbol: "externaldrive.fill", tint: p.ansiMagenta, title: "Full Disk Access",
                    detail: "Optional. Needed for commands that read Mail, Safari or Time Machine data. Turn on Rune in the list.",
                    palette: p, divider: false) {
                    if model.fullDiskAccess {
                        Done(text: "Granted", palette: p)
                    } else {
                        SmallButton(title: "Open Settings", palette: p) { model.openFullDiskAccessSettings() }
                    }
                }
            }
            Label("You can change these anytime in System Settings → Privacy & Security.", systemImage: "info.circle")
                .font(.system(size: 11.5))
                .foregroundColor(Color(nsColor: p.hint))
        }
    }
}

private struct SetupStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var ai = AIService.shared

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 26) {
            Heading(step: .setup, title: "Make it yours", highlight: "yours",
                    subtitle: "Choose how you type commands and set up private AI. Both can be changed later in Settings.",
                    note: "all of it stays on your Mac", palette: p)
            Card(palette: p) {
                Row(symbol: "keyboard", tint: p.accent, title: "Type commands in",
                    detail: model.config.inputMode == .editor ? "Rune's editor: suggestions, highlighting, completion." : "Your zsh prompt: every zsh plugin works as usual.",
                    palette: p) {
                    Picker("", selection: Binding(get: { model.config.inputMode }, set: { model.set("inputMode", $0.rawValue) })) {
                        Text("Rune").tag(InputStyle.editor)
                        Text("zsh").tag(InputStyle.shell)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                Row(symbol: "sparkle", tint: p.ansiYellow, title: "Private AI",
                    detail: aiDetail, palette: p, divider: false) {
                    aiAction
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Good to know")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(nsColor: p.hint))
                HStack(spacing: 16) {
                    Shortcut(keys: "⌘↵", label: "Ask AI", palette: p)
                    Shortcut(keys: "⌘T", label: "New tab", palette: p)
                    Shortcut(keys: "⌘B", label: "Files", palette: p)
                    Shortcut(keys: "⌘,", label: "Settings", palette: p)
                }
            }
        }
    }

    private var aiDetail: String {
        switch ai.status {
        case .ready: return "Runs on this Mac with Ollama. Press ⌘↵ to ask."
        case .noModels: return "Ollama is running. Pull a model to start: ollama pull \(ModelSelection.suggestedModel)"
        case .installedNotRunning: return "Ollama is installed but not running."
        case .notInstalled: return "Optional. Install Ollama to ask questions with ⌘↵."
        case .unreachable: return "Can't reach the configured Ollama server."
        }
    }

    @ViewBuilder
    private var aiAction: some View {
        let p = model.palette
        switch ai.status {
        case .ready(let models):
            Picker("", selection: Binding(get: { ai.activeModel ?? "" }, set: { ai.select(model: $0) })) {
                ForEach(models) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 150)
        case .installedNotRunning:
            SmallButton(title: "Start", palette: p, prominent: true) { ai.startOllama() }
        case .notInstalled:
            SmallButton(title: "Get Ollama", palette: p) { ai.openDownloadPage() }
        default:
            SmallButton(title: "Check Again", palette: p) { ai.refresh() }
        }
    }
}

private struct Shortcut: View {
    let keys: String
    let label: String
    let palette: ChromePalette

    var body: some View {
        HStack(spacing: 7) {
            Text(keys)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundColor(Color(nsColor: palette.text))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: palette.foreground.withAlphaComponent(0.08))))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.1)), lineWidth: 1))
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: palette.secondary))
        }
    }
}
