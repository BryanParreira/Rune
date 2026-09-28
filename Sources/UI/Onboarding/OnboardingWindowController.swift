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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
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
        case welcome, folders, fullDisk, ai, preferences, done

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .folders: return "Folders"
            case .fullDisk: return "Full Disk Access"
            case .ai: return "Local AI"
            case .preferences: return "Preferences"
            case .done: return "Ready"
            }
        }
    }

    enum Access: Equatable { case unknown, granted, denied, missing }

    let store: ConfigStore
    @Published var step: Step = .welcome
    @Published private(set) var folderAccess: [String: Access] = [:]
    @Published private(set) var isRequestingFolders = false
    @Published private(set) var fullDiskAccess = false
    @Published var cliInstalled = false
    @Published var cliMessage: String?
    private var pollTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    static let folders = ["Desktop", "Documents", "Downloads"]

    init(store: ConfigStore) {
        self.store = store
        refreshFolderAccess(requesting: false)
        fullDiskAccess = Self.hasFullDiskAccess()
        cliInstalled = FileManager.default.fileExists(atPath: Self.cliDestination.path)
        $step.sink { [weak self] step in
            if step == .fullDisk { self?.startPolling() } else { self?.stopPolling() }
            if step == .ai { AIService.shared.refresh() }
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

    static var cliDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/rune")
    }

    /// Copies the bundled `rune` launcher to ~/.local/bin (no admin rights needed).
    func installCLI() {
        guard let source = Bundle.main.url(forResource: "rune-cli", withExtension: "sh") else {
            cliMessage = "The launcher script is missing from this build."
            return
        }
        let destination = Self.cliDestination
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            cliInstalled = true
            let path = CommandCatalog.shared.shellPath ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            cliMessage = path.split(separator: ":").contains(where: { $0.hasSuffix(".local/bin") })
                ? "Installed. Type rune in any terminal to open a tab there."
                : "Installed to ~/.local/bin. Add it to your PATH: echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"
        } catch {
            cliMessage = error.localizedDescription
        }
    }
}

// MARK: - Views

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    var body: some View {
        let p = model.palette
        HStack(spacing: 0) {
            // Progress rail.
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .padding(.bottom, 18)
                ForEach(OnboardingModel.Step.allCases, id: \.rawValue) { step in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(nsColor: step.rawValue < model.step.rawValue ? p.accent : (step == model.step ? p.accent.withAlphaComponent(0.25) : p.surface2)))
                                .frame(width: 18, height: 18)
                            if step.rawValue < model.step.rawValue {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                            } else {
                                Text("\(step.rawValue + 1)").font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color(nsColor: step == model.step ? p.text : p.hint))
                            }
                        }
                        Text(step.title)
                            .font(.system(size: 12.5, weight: step == model.step ? .semibold : .regular))
                            .foregroundColor(Color(nsColor: step == model.step ? p.text : p.secondary))
                    }
                    .padding(.vertical, 5)
                }
                Spacer()
            }
            .padding(.top, 44)
            .padding(.horizontal, 24)
            .frame(width: 200, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: p.surface1))

            Rectangle().fill(Color(nsColor: p.outline)).frame(width: 1)

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 48)
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: p.background))
        .tint(Color(nsColor: p.accent))
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .folders: FoldersStep(model: model)
        case .fullDisk: FullDiskStep(model: model)
        case .ai: AIStep(model: model)
        case .preferences: PreferencesStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    private var footer: some View {
        let p = model.palette
        return HStack {
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }
                    .buttonStyle(OnboardingButtonStyle(prominent: false, palette: p))
            }
            Spacer()
            if model.step == .fullDisk && !model.fullDiskAccess || model.step == .folders && !model.allFoldersGranted || model.step == .ai {
                Button("Skip") { model.next() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .padding(.trailing, 12)
            }
            Button(model.step == .done ? "Start using Rune" : (model.step == .welcome ? "Get Started" : "Continue")) {
                model.step == .done ? onFinish() : model.next()
            }
            .buttonStyle(OnboardingButtonStyle(prominent: true, palette: p))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 20)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: p.outline)).frame(height: 1) }
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    let prominent: Bool
    let palette: ChromePalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(prominent ? .white : Color(nsColor: palette.text))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: prominent ? palette.accent : palette.surface2))
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    let palette: ChromePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(Color(nsColor: palette.accent))
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(Color(nsColor: palette.text))
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundColor(Color(nsColor: palette.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
        .padding(.bottom, 26)
    }
}

private struct Card<Content: View>: View {
    let palette: ChromePalette
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: palette.surface1)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(nsColor: palette.outline), lineWidth: 1))
    }
}

private struct StatusPill: View {
    let text: String
    let ok: Bool?
    let palette: ChromePalette

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ok == true ? "checkmark.circle.fill" : (ok == false ? "xmark.circle.fill" : "circle.dashed"))
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundColor(Color(nsColor: ok == true ? palette.success : (ok == false ? palette.error : palette.hint)))
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "sparkles", title: "Welcome to Rune",
                       subtitle: "A fast, private terminal for your Mac. This takes about a minute: Rune will ask for the access a terminal needs, and you can set up local AI.",
                       palette: p)
            VStack(alignment: .leading, spacing: 14) {
                feature("square.stack.3d.up", "Command blocks", "Every command and its output grouped, timed, and easy to copy or re-run.")
                feature("keyboard", "A modern input", "History suggestions, syntax highlighting and completion as you type.")
                feature("lock.shield", "Private by design", "No account, no telemetry. AI runs on your Mac with Ollama.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ text: String) -> some View {
        let p = model.palette
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundColor(Color(nsColor: p.accent))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: p.surface2)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color(nsColor: p.text))
                Text(text).font(.system(size: 12.5)).foregroundColor(Color(nsColor: p.secondary)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FoldersStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "folder.badge.person.crop", title: "Access to your folders",
                       subtitle: "macOS protects Desktop, Documents and Downloads. Commands you run in Rune use Rune's permission, so allowing access now means commands like ls ~/Desktop just work later. macOS will ask once for each folder.",
                       palette: p)
            Card(palette: p) {
                ForEach(OnboardingModel.folders, id: \.self) { name in
                    HStack {
                        Image(systemName: "folder").foregroundColor(Color(nsColor: p.ansiBlue))
                        Text(name).font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                        Spacer()
                        switch model.folderAccess[name] ?? .unknown {
                        case .granted: StatusPill(text: "Allowed", ok: true, palette: p)
                        case .denied: StatusPill(text: "Not allowed", ok: false, palette: p)
                        case .missing: StatusPill(text: "Not present", ok: nil, palette: p)
                        case .unknown: StatusPill(text: "Not asked yet", ok: nil, palette: p)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button(model.isRequestingFolders ? "Waiting for macOS…" : "Allow Access") { model.requestFolderAccess() }
                    .buttonStyle(OnboardingButtonStyle(prominent: !model.allFoldersGranted, palette: p))
                    .disabled(model.isRequestingFolders)
                if model.folderAccess.values.contains(.denied) {
                    Button("Open Privacy Settings") { model.openFilesAndFoldersSettings() }
                        .buttonStyle(OnboardingButtonStyle(prominent: false, palette: p))
                }
            }
            .padding(.top, 18)
        }
    }
}

private struct FullDiskStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "externaldrive.badge.checkmark", title: "Full Disk Access (optional)",
                       subtitle: "Some commands read data macOS locks down, such as Mail, Safari, Time Machine and other apps' containers. Terminals need Full Disk Access for those. You can skip this and turn it on later.",
                       palette: p)
            Card(palette: p) {
                HStack {
                    Text("Status").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                    Spacer()
                    StatusPill(text: model.fullDiskAccess ? "Granted" : "Not granted", ok: model.fullDiskAccess, palette: p)
                }
                if !model.fullDiskAccess {
                    VStack(alignment: .leading, spacing: 6) {
                        instruction("1", "Open Privacy & Security → Full Disk Access.")
                        instruction("2", "Turn on Rune (click + and choose Rune if it isn't listed).")
                        instruction("3", "Come back here. This screen updates by itself.")
                    }
                }
            }
            if !model.fullDiskAccess {
                HStack(spacing: 12) {
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(OnboardingButtonStyle(prominent: true, palette: p))
                    Button("Show Rune in Finder") { model.revealApp() }
                        .buttonStyle(OnboardingButtonStyle(prominent: false, palette: p))
                }
                .padding(.top, 18)
            }
        }
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .bold)).foregroundColor(Color(nsColor: model.palette.accent)).frame(width: 14)
            Text(text).font(.system(size: 12.5)).foregroundColor(Color(nsColor: model.palette.secondary))
        }
    }
}

private struct AIStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var ai = AIService.shared

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "sparkle", title: "Private AI, on your Mac",
                       subtitle: "Press ⌘↵ to ask a question instead of running it. Rune talks only to Ollama on this Mac, and never runs a suggested command without you.",
                       palette: p)
            Card(palette: p) {
                HStack {
                    Text("Ollama").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                    Spacer()
                    if ai.isChecking { ProgressView().controlSize(.small) }
                    StatusPill(text: statusText, ok: statusOK, palette: p)
                }
                if !ai.status.models.isEmpty {
                    HStack {
                        Text("Model").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                        Spacer()
                        Picker("", selection: Binding(get: { ai.activeModel ?? "" }, set: { ai.select(model: $0) })) {
                            ForEach(ai.status.models) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                Toggle(isOn: Binding(get: { model.config.aiEnabled }, set: { model.set("aiEnabled", $0) })) {
                    Text("Enable AI features").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                }
                .toggleStyle(.switch)
            }
            HStack(spacing: 12) {
                switch ai.status {
                case .notInstalled:
                    Button("Download Ollama") { ai.openDownloadPage() }.buttonStyle(OnboardingButtonStyle(prominent: true, palette: p))
                case .installedNotRunning:
                    Button("Start Ollama") { ai.startOllama() }.buttonStyle(OnboardingButtonStyle(prominent: true, palette: p))
                case .noModels:
                    Text("Then run ollama pull \(ModelSelection.suggestedModel) in Rune.")
                        .font(.system(size: 12)).foregroundColor(Color(nsColor: p.secondary))
                default:
                    EmptyView()
                }
                Button("Check Again") { ai.refresh() }.buttonStyle(OnboardingButtonStyle(prominent: false, palette: p))
            }
            .padding(.top, 18)
        }
    }

    private var statusText: String {
        switch ai.status {
        case .ready(let models): return "Running · \(models.count) model\(models.count == 1 ? "" : "s")"
        case .noModels: return "Running, no models yet"
        case .installedNotRunning: return "Installed, not running"
        case .notInstalled: return "Not installed"
        case .unreachable: return "Unreachable"
        }
    }

    private var statusOK: Bool? {
        switch ai.status {
        case .ready: return true
        case .notInstalled, .unreachable: return false
        default: return nil
        }
    }
}

private struct PreferencesStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var updates = UpdateController.shared

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "slider.horizontal.3", title: "Make it yours",
                       subtitle: "A few choices to start with. Everything is in Settings (⌘,) later.",
                       palette: p)
            Card(palette: p) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Type commands in").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                        Text("zsh prompt keeps every zsh plugin working exactly as usual.")
                            .font(.system(size: 11.5)).foregroundColor(Color(nsColor: p.hint))
                    }
                    Spacer()
                    Picker("", selection: Binding(get: { model.config.inputMode }, set: { model.set("inputMode", $0.rawValue) })) {
                        Text("Rune editor").tag(InputStyle.editor)
                        Text("zsh prompt").tag(InputStyle.shell)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                if updates.isAvailable {
                    Divider()
                    Toggle(isOn: $updates.automaticallyChecks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates automatically").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                            Text("Once a day; asks before installing.").font(.system(size: 11.5)).foregroundColor(Color(nsColor: p.hint))
                        }
                    }
                    .toggleStyle(.switch)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The rune command").font(.system(size: 13)).foregroundColor(Color(nsColor: p.text))
                        Text("Open a Rune tab in any folder from another terminal.")
                            .font(.system(size: 11.5)).foregroundColor(Color(nsColor: p.hint))
                    }
                    Spacer()
                    if model.cliInstalled {
                        StatusPill(text: "Installed", ok: true, palette: p)
                    } else {
                        Button("Install") { model.installCLI() }.buttonStyle(OnboardingButtonStyle(prominent: false, palette: p))
                    }
                }
                if let message = model.cliMessage {
                    Text(message).font(.system(size: 11.5)).foregroundColor(Color(nsColor: p.secondary)).textSelection(.enabled)
                }
            }
        }
    }
}

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(symbol: "checkmark.seal", title: "You're all set",
                       subtitle: "A few shortcuts to remember:", palette: p)
            Card(palette: p) {
                shortcut(["↵"], "Run a command")
                shortcut(["⌘", "↵"], "Ask AI")
                shortcut(["⌘", "B"], "Show files")
                shortcut(["⌘", "↑"], "Jump between blocks")
                shortcut(["⌘", ","], "Settings")
            }
        }
    }

    private func shortcut(_ keys: [String], _ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 13)).foregroundColor(Color(nsColor: model.palette.text))
            Spacer()
            HStack(spacing: 4) { ForEach(keys, id: \.self) { Keycap(key: $0, size: 12, palette: model.palette) } }
        }
    }
}
