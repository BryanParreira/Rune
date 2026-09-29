import AppKit
import Combine
import RuneKit
import SwiftUI

/// First-launch guide: asks for the macOS permissions a terminal needs (folder access, optional
/// Full Disk Access), sets up AI and a few preferences. Shown once per Mac; reopen it from
/// Rune → Welcome Guide…
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "RuneOnboardingCompletedVersion"
    static let currentVersion = 1

    static var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: completedKey) < currentVersion
    }

    private let model: OnboardingModel

    init(store: ConfigStore) {
        model = OnboardingModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
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
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
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

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    var body: some View {
        let p = model.palette
        ZStack {
            // Obsidian backdrop with a soft light, echoing the app icon.
            LinearGradient(colors: [Color(nsColor: p.surface2), Color(nsColor: p.background)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(nsColor: p.accent).opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 360)

            VStack(spacing: 0) {
                Group {
                    switch model.step {
                    case .welcome: WelcomeStep(model: model)
                    case .permissions: PermissionsStep(model: model)
                    case .setup: SetupStep(model: model)
                    }
                }
                .id(model.step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                footer
            }
            .padding(.horizontal, 56)
            .padding(.top, 52)
            .padding(.bottom, 32)
        }
        .frame(width: 600, height: 540)
        .animation(.easeOut(duration: 0.22), value: model.step)
        .tint(Color(nsColor: p.accent))
    }

    private var footer: some View {
        let p = model.palette
        return VStack(spacing: 14) {
            Button {
                model.step == .setup ? onFinish() : model.next()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: p.accent)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.defaultAction)

            // Back · progress dots · Skip, with the dots always centered.
            HStack(spacing: 0) {
                Group {
                    if model.step != .welcome {
                        Button("Back") { model.back() }
                            .buttonStyle(.plain)
                    }
                }
                .frame(width: 80, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                        Capsule()
                            .fill(Color(nsColor: step == model.step ? p.text : p.foreground.withAlphaComponent(0.18)))
                            .frame(width: step == model.step ? 18 : 6, height: 6)
                    }
                }
                Spacer(minLength: 0)
                Group {
                    if model.step != .setup {
                        Button("Skip") { onFinish() }
                            .buttonStyle(.plain)
                            .help("You can reopen this from Rune → Welcome Guide")
                    }
                }
                .frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(Color(nsColor: p.secondary))
            .frame(height: 20)
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

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// Title block shared by every step.
private struct Heading: View {
    let title: String
    let subtitle: String
    let palette: ChromePalette

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.4)
                .foregroundColor(Color(nsColor: palette.text))
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(Color(nsColor: palette.secondary))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 440)
    }
}

/// A grouped list of rows, like System Settings.
private struct Group_<Content: View>: View {
    let palette: ChromePalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: palette.foreground.withAlphaComponent(0.045))))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.08)), lineWidth: 1))
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
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: tint.withAlphaComponent(0.14))))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color(nsColor: palette.text))
                    Text(detail).font(.system(size: 12)).foregroundColor(Color(nsColor: palette.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
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
                .padding(.horizontal, 12)
                .frame(height: 26)
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
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            Heading(title: "Welcome to Rune",
                    subtitle: "A fast, private terminal for your Mac. Two quick steps and you're ready.",
                    palette: p)
            HStack(spacing: 12) {
                pill("square.stack.3d.up", "Command blocks")
                pill("keyboard", "Smart input")
                pill("lock.shield", "Private AI")
            }
        }
    }

    private func pill(_ symbol: String, _ text: String) -> some View {
        let p = model.palette
        return HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(Color(nsColor: p.accent))
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundColor(Color(nsColor: p.text))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Color(nsColor: p.foreground.withAlphaComponent(0.06))))
        .overlay(Capsule().stroke(Color(nsColor: p.foreground.withAlphaComponent(0.08)), lineWidth: 1))
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(spacing: 28) {
            Heading(title: "Give Rune access",
                    subtitle: "Commands you run use Rune's permissions. Allow access now and macOS won't interrupt you later.",
                    palette: p)
            Group_(palette: p) {
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
                    detail: "Optional. For commands that read Mail, Safari or backups. Turn on Rune in the list.",
                    palette: p, divider: false) {
                    if model.fullDiskAccess {
                        Done(text: "Granted", palette: p)
                    } else {
                        SmallButton(title: "Open Settings", palette: p) { model.openFullDiskAccessSettings() }
                    }
                }
            }
        }
    }
}

private struct SetupStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var ai = AIService.shared

    var body: some View {
        let p = model.palette
        VStack(spacing: 28) {
            Heading(title: "Make it yours",
                    subtitle: "Pick how you type and set up private AI. You can change this anytime in Settings.",
                    palette: p)
            Group_(palette: p) {
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
