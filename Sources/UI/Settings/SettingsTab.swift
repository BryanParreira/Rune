import AppKit
import Combine
import RuneKit
import ServiceManagement
import SwiftUI

/// Settings, shown as a tab in the main window. Every control writes straight to config.json
/// (or the synced copy), so the file stays the single source of truth and edits made in a text
/// editor show up here live.
final class SettingsTab: TabContent {
    let id = UUID()
    let title = "Settings"
    let runningProgram: String? = nil
    let contentView: NSView
    private let model: SettingsModel

    #if DEBUG
    func debugShow(page: SettingsModel.Page, query: String = "") {
        model.page = page
        model.query = query
    }
    #endif

    init(store: ConfigStore) {
        model = SettingsModel(store: store)
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.safeAreaRegions = []
        // Fills the pane; its content never sets a minimum size that would grow the window.
        host.sizingOptions = []
        contentView = host
    }

    func focus() {
        model.refreshLists()
        contentView.window?.makeFirstResponder(contentView)
    }

    func apply(_ snapshot: ConfigSnapshot) {}
    func closeContent() {}
}

final class SettingsModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case terminal = "Terminal"
        case input = "Input"
        case workflows = "Workflows"
        case ai = "AI"
        case keyboard = "Keyboard shortcuts"
        case sync = "Sync & machines"
        case about = "About"

        var id: String { rawValue }
    }

    let store: ConfigStore
    @Published var page: Page = .appearance
    @Published var query = ""
    @Published private(set) var snapshot: ConfigSnapshot
    @Published private(set) var writeError: String?
    @Published private(set) var themes: [String] = []
    @Published private(set) var fontFamilies: [String] = []
    /// When on, changes are saved under hosts.<this Mac> instead of as shared settings.
    @Published var thisMachineOnly = false
    private var cancellables: Set<AnyCancellable> = []

    init(store: ConfigStore) {
        self.store = store
        snapshot = store.snapshot
        store.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.snapshot = $0
            self?.refreshOverrides()
        }.store(in: &cancellables)
        store.$lastWriteError.receive(on: DispatchQueue.main).sink { [weak self] in self?.writeError = $0 }.store(in: &cancellables)
        refreshLists()
    }

    var config: RuneConfig { snapshot.config }
    var palette: ChromePalette { ChromePalette(theme: snapshot.theme) }

    func refreshLists() {
        themes = store.availableThemes()
        fontFamilies = FontResolver.monospacedFamilies()
    }

    // MARK: Search

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func matches(_ text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || text.localizedCaseInsensitiveContains(q)
    }

    /// Pages that have at least one setting matching the search.
    var visiblePages: [Page] {
        guard isSearching else { return Page.allCases }
        return Page.allCases.filter { page in
            matches(page.rawValue) || SettingsIndex.keywords(for: page).contains(where: matches)
        }
    }

    // MARK: Writing

    func set(_ key: String, _ value: Any?) {
        store.write(key: key, value: value, thisMachineOnly: thisMachineOnly)
        refreshOverrides()
    }

    /// Keys overridden for this Mac, recomputed when the config changes (not on every render).
    @Published private(set) var overriddenKeys: Set<String> = []

    private func refreshOverrides() {
        let keys = RuneConfig.knownKeys.filter { store.hasMachineOverride(key: $0) }
        if keys != overriddenKeys { overriddenKeys = keys }
    }

    func isOverridden(_ key: String) -> Bool { overriddenKeys.contains(key) }
    func clearOverride(_ key: String) {
        store.clearMachineOverride(key: key)
        refreshOverrides()
    }

    func binding<Value: Equatable>(_ key: String, _ get: @escaping (RuneConfig) -> Value, encode: @escaping (Value) -> Any? = { $0 }) -> Binding<Value> {
        Binding(
            get: { get(self.snapshot.config) },
            set: { newValue in
                guard newValue != get(self.snapshot.config) else { return }
                self.set(key, encode(newValue))
            }
        )
    }

    /// Nerd Font to suggest when the chosen font can't draw icons in bold text.
    var suggestedNerdFont: String? {
        guard !config.fontFamily.localizedCaseInsensitiveContains("Nerd Font") else { return nil }
        return fontFamilies.first { $0.hasSuffix("Nerd Font Mono") } ?? fontFamilies.first { $0.contains("Nerd Font") }
    }

    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Rune will read config.json and themes/ from this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // syncPath always lives in the local file; it points at the synced one.
        do {
            try ConfigWriter(file: store.paths.configFile).set("syncPath", to: abbreviateHome(url.path))
            store.reload()
        } catch {
            writeError = error.localizedDescription
        }
    }

    func clearSyncFolder() {
        try? ConfigWriter(file: store.paths.configFile).set("syncPath", to: nil)
        store.reload()
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Search keywords per page, so the sidebar can filter before a page is rendered.
enum SettingsIndex {
    static func keywords(for page: SettingsModel.Page) -> [String] {
        switch page {
        case .appearance:
            return ["Theme", "Font", "Font size", "Line height", "Cursor", "Blinking cursor", "Padding", "Nerd Font", "icons", "colors",
                    "Match system appearance", "Dark Mode", "Light Mode", "Font weight", "bold", "Minimum contrast", "readability",
                    "Dim inactive panes", "split", "Show in Dock", "menu bar", "Cmd-Tab"]
        case .terminal:
            return ["Shell", "Show shell prompt", "PS1", "Starship", "Scrollback", "Option key", "Meta", "Notifications", "Notify when done", "long commands", "Restore", "Reopen", "session", "tabs at launch", "Secrets", "API keys", "tokens", "redact", "Recall", "history", "output search", "Touch ID", "sudo", "fingerprint", "password",
                    "Copy on select", "selection", "Right-click", "paste", "mouse", "Scroll speed", "trackpad"]
        case .workflows:
            return ["Workflows", "saved commands", "snippets", "command palette", "placeholders"]
        case .input:
            return ["New session panel", "welcome", "editor", "history", "completion", "Type commands in", "zsh prompt", "autosuggestions", "syntax highlighting", "plugins"]
        case .ai:
            return ["AI", "Ollama", "Model", "local", "LLM", "Endpoint", "context", "Explain"]
        case .keyboard:
            return KeyboardShortcut.all.map(\.action) + MainMenu.customizableItems().map(\.item.title)
                + ["shortcuts", "keybindings", "hotkey", "global", "login", "launch", "customize", "menu"]
        case .sync:
            return ["Sync folder", "iCloud", "dotfiles", "This Mac only", "machine", "hosts", "per-machine"]
        case .about:
            return ["Version", "License", "Config file", "local-first", "privacy", "telemetry", "Updates", "Check for updates", "Automatically check for updates"]
        }
    }
}

struct KeyboardShortcut: Identifiable {
    let id = UUID()
    let action: String
    let keys: [String]

    static let all: [KeyboardShortcut] = [
        .init(action: "Run command", keys: ["↵"]),
        .init(action: "Insert new line", keys: ["⇧", "↵"]),
        .init(action: "Previous / next command in history", keys: ["↑", "↓"]),
        .init(action: "Complete file or folder", keys: ["⇥"]),
        .init(action: "Ask AI (local model)", keys: ["⌘", "↵"]),
        .init(action: "Stop / close AI answer", keys: ["esc"]),
        .init(action: "Clear input / interrupt running command", keys: ["⌃", "C"]),
        .init(action: "Select previous block", keys: ["⌘", "↑"]),
        .init(action: "Select next block", keys: ["⌘", "↓"]),
        .init(action: "Clear screen", keys: ["⌘", "K"]),
        .init(action: "Toggle file tree", keys: ["⌘", "B"]),
        .init(action: "New tab", keys: ["⌘", "T"]),
        .init(action: "Switch to tab 1–8 / last tab", keys: ["⌘", "1…9"]),
        .init(action: "Next / previous tab", keys: ["⌘", "⇧", "] ["]),
        .init(action: "New window", keys: ["⌘", "N"]),
        .init(action: "Show / hide Rune from any app (default)", keys: ["⌃", "`"]),
        .init(action: "Command palette", keys: ["⌘", "P"]),
        .init(action: "Reopen closed tab or pane", keys: ["⌘", "⇧", "T"]),
        .init(action: "Rename a tab", keys: ["double-click"]),
        .init(action: "Open a link or file path in the output", keys: ["⌘", "click"]),
        .init(action: "Split pane right", keys: ["⌘", "D"]),
        .init(action: "Split pane down", keys: ["⌘", "⇧", "D"]),
        .init(action: "Close pane (or tab)", keys: ["⌘", "W"]),
        .init(action: "Next / previous pane", keys: ["⌘", "] ["]),
        .init(action: "Move to the pane in a direction", keys: ["⌥", "⌘", "←→↑↓"]),
        .init(action: "Next workflow placeholder", keys: ["⇥"]),
        .init(action: "Find in output / file", keys: ["⌘", "F"]),
        .init(action: "Find next / previous", keys: ["⌘", "G / ⇧⌘G"]),
        .init(action: "Settings", keys: ["⌘", ","]),
    ]
}

// MARK: - Layout

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    static let sidebarWidth: CGFloat = 212
    static let contentMaxWidth: CGFloat = 680

    var body: some View {
        let palette = model.palette
        VStack(spacing: 0) {
            Text("Settings")
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: palette.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
            HStack(spacing: 0) {
                SettingsSidebar(model: model)
                    .frame(width: Self.sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                Rectangle().fill(Color(nsColor: palette.outline)).frame(width: 1)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error = model.writeError {
                            SettingsNotice(text: error, palette: palette)
                        }
                        page
                    }
                    .frame(maxWidth: Self.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // Fill the whole tab; otherwise AppKit centers the content vertically in tall windows.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: palette.background))
        .tint(Color(nsColor: palette.accent))
    }

    @ViewBuilder
    private var page: some View {
        if model.isSearching {
            ForEach(model.visiblePages) { page in
                pageContent(page)
                    .padding(.bottom, 24)
            }
            if model.visiblePages.isEmpty {
                Text("No settings match “\(model.query)”")
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: model.palette.hint))
            }
        } else {
            pageContent(model.page)
        }
    }

    @ViewBuilder
    private func pageContent(_ page: SettingsModel.Page) -> some View {
        switch page {
        case .appearance: AppearancePage(model: model)
        case .terminal: TerminalPage(model: model)
        case .input: InputPage(model: model)
        case .workflows: WorkflowsPage(model: model)
        case .ai: AIPage(model: model)
        case .keyboard: KeyboardPage(model: model)
        case .sync: SyncPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(Color(nsColor: palette.secondary))
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(Color(nsColor: palette.text))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .padding(.bottom, 4)

            ForEach(model.visiblePages) { page in
                SidebarItem(title: page.rawValue, selected: !model.isSearching && model.page == page, palette: palette) {
                    model.query = ""
                    model.page = page
                }
            }

            Spacer(minLength: 12)

            Button {
                AppDelegate.openInEditor(model.store.writableConfigFile)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open settings file")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(Color(nsColor: palette.text))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.16)), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }
}

private struct SidebarItem: View {
    let title: String
    let selected: Bool
    let palette: ChromePalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundColor(selected ? Color(nsColor: palette.onAccent) : Color(nsColor: hovering ? palette.text : palette.secondary.withAlphaComponent(0.8)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Color(nsColor: palette.accent) : (hovering ? Color(nsColor: palette.surface1) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Building blocks

/// Page title, 23pt bold.
struct PageTitle: View {
    let text: String
    let palette: ChromePalette
    var body: some View {
        Text(text)
            .font(.serif(32))
            .foregroundColor(Color(nsColor: palette.text))
            .padding(.bottom, 13)
    }
}

/// Section header, 16pt.
struct SectionHeader: View {
    let text: String
    let palette: ChromePalette
    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(Color(nsColor: palette.text))
            .padding(.top, 14)
            .padding(.bottom, 12)
    }
}

struct SettingsDivider: View {
    let palette: ChromePalette
    var body: some View {
        Rectangle().fill(Color(nsColor: palette.outline)).frame(height: 1).padding(.vertical, 12)
    }
}

struct SettingsNotice: View {
    let text: String
    let palette: ChromePalette
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(nsColor: palette.error))
            Text(text).font(.system(size: 12)).foregroundColor(Color(nsColor: palette.text))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: palette.error.withAlphaComponent(0.12))))
        .padding(.bottom, 16)
    }
}

/// Label on the left, control on the right, optional description below; hidden when it
/// doesn't match the search.
struct SettingRow<Control: View>: View {
    @ObservedObject var model: SettingsModel
    let title: String
    var key: String?
    var detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        if model.matches(title) || model.matches(detail ?? "") {
            let palette = model.palette
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 16) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14))
                            .foregroundColor(Color(nsColor: palette.text))
                        if let key, model.isOverridden(key) {
                            Button { model.clearOverride(key) } label: {
                                Text("This Mac")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: palette.accent.withAlphaComponent(0.18))))
                                    .foregroundColor(Color(nsColor: palette.accent))
                            }
                            .buttonStyle(.plain)
                            .help("Overridden on this Mac. Click to use the shared value again.")
                        }
                    }
                    Spacer(minLength: 16)
                    control()
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: palette.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, 100)
                }
            }
            .padding(.bottom, 18)
        }
    }
}

/// Bordered dropdown in the Warp settings style; opens a native menu below itself.
struct DropdownField<Value: Hashable>: View {
    let selection: Binding<Value>
    let options: [Value]
    let label: (Value) -> String
    let palette: ChromePalette
    var width: CGFloat = 220
    @State private var hovering = false

    var body: some View {
        Button(action: showMenu) {
            HStack {
                Text(label(selection.wrappedValue))
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: palette.text))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(nsColor: palette.secondary))
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: hovering ? palette.surface1 : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.16)), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        for option in options {
            let item = ClosureMenuItem(title: label(option)) { selection.wrappedValue = option }
            item.state = option == selection.wrappedValue ? .on : .off
            menu.addItem(item)
        }
        // Drop the menu just below the pointer, which is on the field.
        let location = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: NSPoint(x: location.x - 8, y: location.y - 12), in: nil)
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() { handler() }
}

/// "−  value  +" number control.
struct NumberField: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let palette: ChromePalette

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", delta: -step)
            Text(format(value.wrappedValue))
                .font(.system(size: 13).monospacedDigit())
                .foregroundColor(Color(nsColor: palette.text))
                .frame(minWidth: 56)
            stepButton("plus", delta: step)
        }
        .frame(height: 28)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(Color(nsColor: palette.foreground.withAlphaComponent(0.16)), lineWidth: 1)
        )
    }

    private func stepButton(_ symbol: String, delta: Double) -> some View {
        Button {
            let next = min(range.upperBound, max(range.lowerBound, value.wrappedValue + delta))
            value.wrappedValue = (next / step).rounded() * step
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: palette.secondary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SwitchControl: View {
    let isOn: Binding<Bool>
    var body: some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

struct LinkButton: View {
    let title: String
    let palette: ChromePalette
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14)).foregroundColor(Color(nsColor: palette.accent))
        }
        .buttonStyle(.plain)
    }
}

struct Keycaps: View {
    let keys: [String]
    let palette: ChromePalette
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Keycap(key: key, size: 12, palette: palette)
            }
        }
    }
}

// MARK: - Pages

struct AppearancePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Appearance", palette: p)

            SectionHeader(text: "Themes", palette: p)
            SettingRow(model: model, title: model.config.followSystemAppearance ? "Theme in Light Mode" : "Theme", key: "theme",
                       detail: "Add your own as themes/<name>.json in the config folder.") {
                DropdownField(selection: model.binding("theme", { $0.theme }), options: model.themes, label: { Theme.displayName($0) }, palette: p)
            }
            SettingRow(model: model, title: "Match system appearance", key: "followSystemAppearance",
                       detail: "Switch themes when macOS switches between Light and Dark Mode.") {
                SwitchControl(isOn: model.binding("followSystemAppearance", { $0.followSystemAppearance }))
            }
            if model.config.followSystemAppearance {
                SettingRow(model: model, title: "Theme in Dark Mode", key: "darkTheme") {
                    DropdownField(selection: model.binding("darkTheme", { $0.darkTheme }), options: model.themes, label: { Theme.displayName($0) }, palette: p)
                }
            }
            SettingRow(model: model, title: "Minimum contrast", key: "minimumContrast",
                       detail: "Raises hard-to-read text colors (dim grey, yellow on white…) until they're easy to read on the background.") {
                SwitchControl(isOn: model.binding("minimumContrast", { $0.minimumContrast }))
            }

            SectionHeader(text: "Text", palette: p)
            SettingRow(model: model, title: "Font", key: "fontFamily", detail: fontDetail) {
                DropdownField(selection: model.binding("fontFamily", { $0.fontFamily }), options: fontOptions, label: { $0 }, palette: p, width: 260)
            }
            if let nerd = model.suggestedNerdFont, model.matches("Nerd Font icons") {
                HStack(spacing: 6) {
                    Text("Icons in bold text need a Nerd Font.")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: p.secondary))
                    LinkButton(title: "Use \(nerd)", palette: p) { model.set("fontFamily", nerd) }
                        .font(.system(size: 12))
                }
                .padding(.top, -10)
                .padding(.bottom, 18)
            }
            SettingRow(model: model, title: "Font size", key: "fontSize") {
                NumberField(value: model.binding("fontSize", { $0.fontSize }), range: 6...72, step: 1, format: { "\(Int($0)) pt" }, palette: p)
            }
            SettingRow(model: model, title: "Font weight", key: "fontWeight", detail: "Uses the nearest weight the font has.") {
                DropdownField(selection: model.binding("fontWeight", { $0.fontWeight }), options: RuneConfig.fontWeights,
                              label: { $0.capitalized }, palette: p, width: 160)
            }
            SettingRow(model: model, title: "Line height", key: "lineHeight") {
                NumberField(value: model.binding("lineHeight", { $0.lineHeight }), range: 0.8...3, step: 0.05, format: { String(format: "%.2f", $0) }, palette: p)
            }

            SectionHeader(text: "Cursor", palette: p)
            SettingRow(model: model, title: "Cursor type", key: "cursorStyle") {
                DropdownField(selection: model.binding("cursorStyle", { $0.cursorStyle }, encode: { $0.rawValue }),
                              options: CursorShape.allCases, label: { $0.rawValue.capitalized }, palette: p, width: 160)
            }
            SettingRow(model: model, title: "Blinking cursor", key: "cursorBlink") {
                SwitchControl(isOn: model.binding("cursorBlink", { $0.cursorBlink }))
            }

            SectionHeader(text: "Window", palette: p)
            SettingRow(model: model, title: "Horizontal padding", key: "paddingX") {
                NumberField(value: model.binding("paddingX", { $0.paddingX }), range: 0...200, step: 2, format: { "\(Int($0)) pt" }, palette: p)
            }
            SettingRow(model: model, title: "Top padding", key: "paddingY") {
                NumberField(value: model.binding("paddingY", { $0.paddingY }), range: 0...200, step: 2, format: { "\(Int($0)) pt" }, palette: p)
            }
            SettingRow(model: model, title: "Dim inactive panes", key: "dimInactivePanes", detail: "In a split, fade the panes you're not typing in.") {
                SwitchControl(isOn: model.binding("dimInactivePanes", { $0.dimInactivePanes }))
            }
            SettingRow(model: model, title: "Show in Dock", key: "showDockIcon",
                       detail: "Off: Rune leaves the Dock and ⌘-Tab and lives in the menu bar and behind the global hotkey.") {
                SwitchControl(isOn: model.binding("showDockIcon", { $0.showDockIcon }))
            }
        }
    }

    private var fontDetail: String {
        "Any installed monospaced font."
    }

    private var fontOptions: [String] {
        let current = model.config.fontFamily
        return model.fontFamilies.contains(current) ? model.fontFamilies : [current] + model.fontFamilies
    }
}

struct TerminalPage: View {
    @ObservedObject var model: SettingsModel
    @State private var shellDraft = ""

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Terminal", palette: p)

            SettingRow(model: model, title: "Shell", key: "shell", detail: "Leave empty to use your login shell. Blocks and the input editor need zsh.") {
                TextField("Login shell", text: $shellDraft, onCommit: {
                    let value = shellDraft.trimmingCharacters(in: .whitespaces)
                    model.set("shell", value.isEmpty ? nil : value)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(width: 220, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: p.foreground.withAlphaComponent(0.16)), lineWidth: 1))
                .onAppear { shellDraft = model.config.shell ?? "" }
                .onDisappear {
                    let value = shellDraft.trimmingCharacters(in: .whitespaces)
                    if value != (model.config.shell ?? "") { model.set("shell", value.isEmpty ? nil : value) }
                }
            }
            SettingRow(model: model, title: "Show shell prompt in blocks", key: "honorPrompt",
                       detail: "Off: Rune shows the folder and git branch itself. On: your PS1 (Starship, oh-my-zsh…) appears in each block. Applies to new tabs.") {
                SwitchControl(isOn: model.binding("honorPrompt", { $0.honorPrompt }))
            }
            SettingRow(model: model, title: "Scrollback lines", key: "scrollback", detail: "Applies to new tabs.") {
                NumberField(value: model.binding("scrollback", { Double($0.scrollback) }, encode: { Int($0) }),
                            range: 1_000...200_000, step: 1_000, format: { "\(Int($0))" }, palette: p)
            }
            SettingRow(model: model, title: "Option key acts as Meta", key: "optionAsMeta", detail: "Turn off to type special characters with Option.") {
                SwitchControl(isOn: model.binding("optionAsMeta", { $0.optionAsMeta }))
            }
            SettingRow(model: model, title: "Copy on select", key: "copyOnSelect",
                       detail: "Selecting text in the output copies it (hidden secrets stay hidden).") {
                SwitchControl(isOn: model.binding("copyOnSelect", { $0.copyOnSelect }))
            }
            SettingRow(model: model, title: "Right-click in the output", key: "rightClick",
                       detail: "Programs that use the mouse (vim, htop…) still get the click.") {
                DropdownField(selection: model.binding("rightClick", { $0.rightClick }), options: ["menu", "paste"],
                              label: { $0 == "paste" ? "Pastes" : "Shows the menu" }, palette: p, width: 180)
            }
            SettingRow(model: model, title: "Scroll speed", key: "scrollSpeed") {
                NumberField(value: model.binding("scrollSpeed", { $0.scrollSpeed }), range: 0.25...5, step: 0.25,
                            format: { String(format: "%.2g×", $0) }, palette: p)
            }
            SettingRow(model: model, title: "Rune's input over SSH", key: "remoteInput",
                       detail: "When ssh, mosh, docker/kubectl exec, su or sudo -i reaches a shell (bash or zsh), Rune can keep its input box there: blocks, suggestions and ⌘↵ AI. It asks first; logins and passwords always go straight to the session.") {
                HStack(spacing: 12) {
                    Button("Forget “Always” hosts") { TerminalSession.forgetRemoteHosts() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: p.accent))
                    DropdownField(selection: model.binding("remoteInput", { $0.remoteInput }), options: ["ask", "off"],
                                  label: { $0 == "off" ? "Never offer" : "Ask" }, palette: p, width: 140)
                }
            }
            SettingRow(model: model, title: "Open ⌘-clicked files in", key: "openFilesIn",
                       detail: "⌘-click a path in the output (like src/app.ts:42:7) to open it. Your editor opens it at that line when it's VS Code, Cursor, Windsurf or Zed.") {
                DropdownField(selection: model.binding("openFilesIn", { $0.openFilesIn }), options: ["editor", "rune"],
                              label: { $0 == "rune" ? "Rune's preview" : "My editor" }, palette: p, width: 180)
            }
            SettingRow(model: model, title: "Use Touch ID for sudo",
                       detail: "sudo asks for your fingerprint (or Apple Watch) instead of your password, in any terminal. Rune adds one line to /etc/pam.d/sudo_local, which macOS keeps across updates; macOS asks for your administrator password to make the change.") {
                TouchIDSudoControl(palette: p)
            }
            SettingRow(model: model, title: "Rune Recall", key: "recallEnabled",
                       detail: "Keeps a searchable history of the commands you run and their output (last 2,000 lines each), stored only on this Mac with secrets removed. Commands typed with a leading space are skipped. Search it with ⌃R or ⇧⌘H.") {
                SwitchControl(isOn: model.binding("recallEnabled", { $0.recallEnabled }))
            }
            SettingRow(model: model, title: "Keep Recall history for", key: "recallDays") {
                NumberField(value: model.binding("recallDays", { $0.recallDays }), range: 1...3650, step: 30,
                            format: { "\(Int($0)) days" }, palette: p)
            }
            SettingRow(model: model, title: "Clear Recall history", detail: "Deletes everything Recall has stored on this Mac.") {
                Button("Clear…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear Recall history?"
                    alert.informativeText = "Every recorded command and its output will be deleted from this Mac. This can't be undone."
                    alert.addButton(withTitle: "Clear History")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .warning
                    if alert.runModal() == .alertFirstButtonReturn { RecallService.shared.removeAll() }
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(nsColor: p.error))
            }
            SettingRow(model: model, title: "Hide secrets in output", key: "hideSecrets",
                       detail: "Masks API keys, tokens and private keys (AWS, GitHub, OpenAI, Stripe, Slack…) on screen; click one to show it. Secrets are always removed before anything is sent to AI.") {
                SwitchControl(isOn: model.binding("hideSecrets", { $0.hideSecrets }))
            }
            SettingRow(model: model, title: "Reopen windows and tabs at launch", key: "restoreSession",
                       detail: "Brings back your windows, tabs, split panes and their folders after quitting or updating. Only folder and file paths are saved, on this Mac.") {
                SwitchControl(isOn: model.binding("restoreSession", { $0.restoreSession }))
            }
            SettingRow(model: model, title: "Notify when long commands finish", key: "notifyWhenDone",
                       detail: "A macOS notification when a command finishes while Rune is in the background or its tab isn't visible. Click it to jump back.") {
                SwitchControl(isOn: model.binding("notifyWhenDone", { $0.notifyWhenDone }))
            }
            SettingRow(model: model, title: "Only for commands longer than", key: "notifyAfterSeconds") {
                NumberField(value: model.binding("notifyAfterSeconds", { $0.notifyAfterSeconds }),
                            range: 1...3600, step: 5, format: { "\(Int($0)) s" }, palette: p)
            }
        }
    }
}

struct InputPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Input", palette: p)
            SettingRow(model: model, title: "Type commands in", key: "inputMode",
                       detail: "Rune editor: the input box at the bottom, with history suggestions (→ to accept), syntax highlighting and Tab completion. zsh prompt: type directly at your shell prompt so every zsh plugin (autosuggestions, syntax highlighting, vi-mode, fzf ⌃R…) works exactly as in any terminal; blocks still work. Applies to new tabs.") {
                DropdownField(selection: model.binding("inputMode", { $0.inputMode }, encode: { $0.rawValue }),
                              options: InputStyle.allCases,
                              label: { $0 == .editor ? "Rune editor" : "zsh prompt" }, palette: p, width: 180)
            }
            SettingRow(model: model, title: "Show “New session” panel", key: "showWelcome", detail: "Shortcut tips above the input editor in new tabs.") {
                SwitchControl(isOn: model.binding("showWelcome", { $0.showWelcome }))
            }
            SettingRow(model: model, title: "Command history", detail: "Up/Down cycles through ~/.zsh_history plus commands run in Rune. Suggestions from history appear in grey as you type.") {
                EmptyView()
            }
            SettingRow(model: model, title: "Tab completion", detail: "Completes files and folders relative to the current directory.") {
                EmptyView()
            }
        }
    }
}

struct AIPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var ai = AIService.shared
    @State private var endpointDraft = ""

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "AI", palette: p)
            Text("Rune is a terminal first: Enter always runs your command in the shell. Only ⌘↵ (or Explain on a failed block) sends a question to Ollama on your own Mac, and suggested commands always wait for you to press Run.")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: p.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            SettingRow(model: model, title: "Enable AI", key: "aiEnabled",
                       detail: "Off: Rune never contacts Ollama and hides the model chip, ⌘↵ and Explain.") {
                SwitchControl(isOn: model.binding("aiEnabled", { $0.aiEnabled }))
            }

            if model.config.aiEnabled {

            SettingRow(model: model, title: "Status", detail: statusDetail) {
                HStack(spacing: 14) {
                    if ai.isChecking { ProgressView().controlSize(.small) }
                    statusAction(p)
                    LinkButton(title: "Refresh", palette: p) { ai.refresh(); model.refreshLists() }
                }
            }

            if let notice = ai.fallbackNotice {
                SettingsNotice(text: notice, palette: p)
            }

            SettingRow(model: model, title: "Model", key: "aiModel",
                       detail: ai.status.models.isEmpty ? "Models installed on this Mac appear here." : "Installed on this Mac. Your choice is saved in config.json.") {
                if ai.status.models.isEmpty {
                    Text("None").font(.system(size: 13)).foregroundColor(Color(nsColor: p.hint))
                } else {
                    DropdownField(
                        selection: Binding(get: { ai.activeModel ?? "" }, set: { ai.select(model: $0) }),
                        options: ai.status.models.map(\.name),
                        label: { name in
                            let info = ai.status.models.first { $0.name == name }?.displaySize
                            return info.map { "\(name)   \($0)" } ?? name
                        },
                        palette: p, width: 280)
                }
            }

            SettingRow(model: model, title: "Send last command as context", key: "aiIncludeBlockContext",
                       detail: "Includes the most recent block's command and the end of its output (at most 4,000 characters). A block you select with ⌘↑ is always included.") {
                SwitchControl(isOn: model.binding("aiIncludeBlockContext", { $0.aiIncludeBlockContext }))
            }

            SettingsDivider(palette: p)

            SettingRow(model: model, title: "Ollama server", key: "ollamaEndpoint",
                       detail: "Leave empty to use $OLLAMA_HOST or http://localhost:11434. Currently: \(ai.endpoint.url.absoluteString)\(ai.endpoint.isLocal ? " (this Mac)" : " — requests leave this Mac").") {
                TextField("http://localhost:11434", text: $endpointDraft, onCommit: {
                    let value = endpointDraft.trimmingCharacters(in: .whitespaces)
                    model.set("ollamaEndpoint", value.isEmpty ? nil : value)
                })
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(width: 240, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: p.foreground.withAlphaComponent(0.16)), lineWidth: 1))
                .onAppear { endpointDraft = model.config.ollamaEndpoint ?? "" }
                .onDisappear {
                    let value = endpointDraft.trimmingCharacters(in: .whitespaces)
                    if value != (model.config.ollamaEndpoint ?? "") { model.set("ollamaEndpoint", value.isEmpty ? nil : value) }
                }
            }
            }
        }
        .onAppear { ai.refresh() }
    }

    private var statusDetail: String {
        switch ai.status {
        case .ready(let models): return "Running · \(models.count) model\(models.count == 1 ? "" : "s") installed"
        case .noModels: return "Running, but no models are installed yet."
        case .installedNotRunning(let models): return "Installed but not running" + (models.isEmpty ? "." : " · on disk: \(models.joined(separator: ", "))")
        case .notInstalled: return "Ollama isn't installed on this Mac."
        case .unreachable(let url): return "Can't reach \(url)."
        }
    }

    @ViewBuilder
    private func statusAction(_ p: ChromePalette) -> some View {
        switch ai.status {
        case .notInstalled: LinkButton(title: "Download Ollama", palette: p) { ai.openDownloadPage() }
        case .installedNotRunning: LinkButton(title: "Start Ollama", palette: p) { ai.startOllama() }
        case .noModels:
            LinkButton(title: "Pull \(ModelSelection.suggestedModel)", palette: p) {
                NSApp.sendAction(#selector(MainWindowController.pullSuggestedModel(_:)), to: nil, from: nil)
            }
        default: EmptyView()
        }
    }
}

struct KeyboardPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Keyboard shortcuts", palette: p)
            SettingRow(model: model, title: "Show or hide Rune from anywhere", key: "globalHotkey",
                       detail: hotkeyDetail) {
                DropdownField(selection: model.binding("globalHotkey", { $0.globalHotkey }),
                              options: Self.hotkeyChoices(current: model.config.globalHotkey),
                              label: { $0 == "off" ? "Off" : GlobalHotKey.display($0) }, palette: p, width: 140)
            }
            SettingRow(model: model, title: "Open Rune at login",
                       detail: "Starts quietly in the background, so the shortcut above works right after you log in.") {
                LoginItemToggle()
            }
            SettingsDivider(palette: p)
            MenuShortcutsSection(model: model)
            SettingsDivider(palette: p)
            SectionHeader(text: "In the input and the output", palette: p)
            // Menu commands are listed (and changed) above.
            let menuTitles = Set(MainMenu.customizableItems().map { $0.item.title.lowercased() })
            let rows = KeyboardShortcut.all.filter { !menuTitles.contains($0.action.lowercased()) && (model.matches($0.action) || model.matches("shortcuts")) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, shortcut in
                HStack {
                    Text(shortcut.action)
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: p.text))
                    Spacer()
                    Keycaps(keys: shortcut.keys, palette: p)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: index % 2 == 0 ? p.surface1 : .clear))
            }
        }
    }
}

extension KeyboardPage {
    static func hotkeyChoices(current: String) -> [String] {
        let presets = ["ctrl+`", "option+`", "option+space", "ctrl+option+t", "off"]
        return presets.contains(current) ? presets : [current] + presets
    }

    var hotkeyDetail: String {
        let spec = model.config.globalHotkey
        if spec == "off" { return "Off. Choose a shortcut to bring Rune forward from any app." }
        if GlobalHotKey.parse(spec) == nil { return "“\(spec)” isn't a shortcut Rune understands (try \"ctrl+`\" or \"option+space\")." }
        if GlobalHotKey.shared.current != spec { return "Another app is already using \(GlobalHotKey.display(spec)). Pick a different one." }
        return "Press \(GlobalHotKey.display(spec)) in any app to bring Rune forward; press it again to hide it."
    }
}

/// Registers Rune as a login item (System Settings → General → Login Items).
struct LoginItemToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        SwitchControl(isOn: Binding(get: { isOn }, set: { newValue in
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
            isOn = SMAppService.mainApp.status == .enabled
        }))
    }
}

struct SyncPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Sync & machines", palette: p)

            SettingRow(model: model, title: "Sync folder",
                       detail: "Point this at iCloud Drive or a dotfiles repo to share config.json and themes/ between Macs. Rune never uploads anything itself.") {
                HStack(spacing: 14) {
                    if model.config.syncPath != nil {
                        LinkButton(title: "Stop syncing", palette: p) { model.clearSyncFolder() }
                    }
                    LinkButton(title: model.config.syncPath == nil ? "Choose folder…" : "Change…", palette: p) { model.chooseSyncFolder() }
                }
            }
            if let path = model.config.syncPath {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .padding(.top, -10)
                    .padding(.bottom, 18)
            }

            SettingsDivider(palette: p)

            SettingRow(model: model, title: "Save changes for this Mac only",
                       detail: "When on, settings you change here are stored under hosts.\(model.store.hostName) and override the shared values on this Mac only.") {
                SwitchControl(isOn: $model.thisMachineOnly)
            }
            SettingRow(model: model, title: "This Mac", detail: "The name used for per-machine overrides (System Settings → General → Sharing → Local hostname).") {
                Text(model.store.hostName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Color(nsColor: p.secondary))
            }
        }
    }
}

/// Update status and the automatic-check switch.
struct UpdateRows: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        let p = model.palette
        if updates.isAvailable {
            SettingRow(model: model, title: "Updates", detail: lastCheckedText) {
                LinkButton(title: "Check for updates", palette: p) { updates.checkForUpdates(nil) }
                    .disabled(!updates.canCheck)
                    .opacity(updates.canCheck ? 1 : 0.5)
            }
            SettingRow(model: model, title: "Automatically check for updates",
                       detail: "Once a day Rune downloads the release feed and asks before installing anything. Nothing about you or your machine is sent.") {
                SwitchControl(isOn: $updates.automaticallyChecks)
            }
        } else {
            SettingRow(model: model, title: "Updates", detail: "This build has no update feed (local or development build).") {
                EmptyView()
            }
        }
    }

    private var lastCheckedText: String {
        guard let date = updates.lastChecked else { return "Not checked yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }
}

struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "About", palette: p)

            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rune").font(.system(size: 18, weight: .semibold)).foregroundColor(Color(nsColor: p.text))
                    Text("Local-first terminal for macOS").font(.system(size: 13)).foregroundColor(Color(nsColor: p.secondary))
                }
            }
            .padding(.bottom, 8)

            SettingsDivider(palette: p)

            UpdateRows(model: model)
            SettingRow(model: model, title: "Version") {
                HStack(spacing: 8) {
                    Text("\(version) (\(build))")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(nsColor: p.secondary))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(version) (\(build))", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundColor(Color(nsColor: p.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("Copy version")
                }
            }
            SettingRow(model: model, title: "Privacy", detail: "No accounts, no telemetry, no cloud services. Everything stays on this Mac unless you point it somewhere yourself.") {
                EmptyView()
            }
            SettingRow(model: model, title: "Config file", detail: model.store.writableConfigFile.path) {
                LinkButton(title: "Reveal in Finder", palette: p) {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.writableConfigFile])
                }
            }
            if !model.snapshot.warnings.isEmpty {
                SettingsDivider(palette: p)
                SectionHeader(text: "Problems in your config", palette: p)
                ForEach(Array(model.snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: p.secondary))
                        .padding(.bottom, 6)
                }
            }
            SettingRow(model: model, title: "License", detail: "© 2026 Bryan Bernardo Parreira. All rights reserved. Rune is free to use; see the license for terms. Built with open-source SwiftTerm and Sparkle.") {
                LinkButton(title: "Acknowledgements", palette: p) {
                    guard let path = Bundle.main.path(forResource: "Acknowledgements", ofType: "txt") else { return }
                    (NSApp.keyWindow?.windowController as? MainWindowController)?.openFile(path: path, pinned: true)
                }
            }
        }
    }
}

struct WorkflowsPage: View {
    @ObservedObject var model: SettingsModel
    /// Index being edited; `workflows.count` means a new one.
    @State private var editing: Int?
    @State private var name = ""
    @State private var command = ""
    @State private var summary = ""

    private var workflows: [Workflow] { model.config.workflows }

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Workflows", palette: p)
            Text("Saved commands you can run from the command palette (⌘P). Write {{name}} for a value to fill in: Rune selects each one in turn and Tab moves to the next. Workflows live in config.json, so they sync along with your settings.\n\nShare workflows with your team by committing a .rune/workflows.json file to a repository (same format: a list of {\"name\", \"command\", \"description\"}). They appear in the palette, marked Project, whenever you're inside that repository.")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: p.secondary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)

            ForEach(Array(workflows.enumerated()), id: \.offset) { index, workflow in
                if editing == index {
                    form(palette: p)
                } else {
                    row(workflow, index: index, palette: p)
                }
                SettingsDivider(palette: p)
            }
            if editing == workflows.count {
                form(palette: p)
            } else if editing == nil {
                Button {
                    begin(index: workflows.count, with: nil)
                } label: {
                    Label("Add Workflow", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(nsColor: p.accent))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
    }

    private func row(_ workflow: Workflow, index: Int, palette p: ChromePalette) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: p.ansiYellow))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: p.text))
                Text(workflow.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let description = workflow.description {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(nsColor: p.hint))
                }
            }
            Spacer()
            if editing == nil {
                Button("Edit") { begin(index: index, with: workflow) }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(nsColor: p.accent))
                Button("Delete") { save(removing: index) }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(nsColor: p.error))
            }
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 12)
    }

    private func form(palette p: ChromePalette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Name", text: $name, placeholder: "Deploy to staging", mono: false, palette: p)
            field("Command", text: $command, placeholder: "git push {{remote}} {{branch}}", mono: true, palette: p)
            field("Description", text: $summary, placeholder: "Optional", mono: false, palette: p)
            HStack(spacing: 14) {
                Button("Save") { save(removing: nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(nsColor: command.trimmingCharacters(in: .whitespaces).isEmpty ? p.hint : p.accent))
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { editing = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: p.secondary))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: p.surface1)))
        .padding(.vertical, 10)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool, palette p: ChromePalette) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: p.secondary))
                .frame(width: 84, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundColor(Color(nsColor: p.text))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: p.foreground.withAlphaComponent(0.16)), lineWidth: 1))
        }
    }

    private func begin(index: Int, with workflow: Workflow?) {
        name = workflow?.name ?? ""
        command = workflow?.command ?? ""
        summary = workflow?.description ?? ""
        editing = index
    }

    /// Writes the list back to config.json: the edited entry saved, or `removing` deleted.
    private func save(removing: Int?) {
        var list = workflows
        if let removing, list.indices.contains(removing) {
            list.remove(at: removing)
        } else if let editing {
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else { return }
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            let trimmedSummary = summary.trimmingCharacters(in: .whitespaces)
            let workflow = Workflow(name: trimmedName.isEmpty ? trimmedCommand : trimmedName, command: trimmedCommand,
                                    description: trimmedSummary.isEmpty ? nil : trimmedSummary)
            if list.indices.contains(editing) { list[editing] = workflow } else { list.append(workflow) }
        }
        model.set("workflows", list.map(\.jsonObject))
        editing = nil
    }
}

/// Status and on/off button for Touch ID for sudo.
struct TouchIDSudoControl: View {
    let palette: ChromePalette
    @State private var enabled = TouchIDSudo.isEnabled
    @State private var message: String?

    var body: some View {
        let p = palette
        HStack(spacing: 10) {
            if let message {
                Text(message).font(.system(size: 11.5)).foregroundColor(Color(nsColor: p.error)).lineLimit(2)
            }
            if !TouchIDSudo.isAvailable {
                Text("No Touch ID on this Mac").font(.system(size: 12)).foregroundColor(Color(nsColor: p.hint))
            } else {
                if enabled {
                    Label("On", systemImage: "touchid").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(nsColor: p.success))
                }
                Button(enabled ? "Turn Off…" : "Turn On…") {
                    switch TouchIDSudo.set(enabled: !enabled) {
                    case .done: message = nil
                    case .cancelled: break
                    case .failed(let reason): message = reason
                    }
                    enabled = TouchIDSudo.isEnabled
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Color(nsColor: p.accent))
            }
        }
        .onAppear { enabled = TouchIDSudo.isEnabled }
    }
}

/// Every menu command with its shortcut; click one and press new keys to change it. Written
/// to `keyboardShortcuts` in config.json, so it syncs like any other setting.
struct MenuShortcutsSection: View {
    @ObservedObject var model: SettingsModel
    @State private var recording: String?
    @State private var monitor: Any?

    var body: some View {
        let p = model.palette
        let items = MainMenu.customizableItems().filter { model.matches($0.item.title) || model.matches("shortcuts") || model.matches("menu") }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(text: "Menu commands", palette: p)
            Text("Click a shortcut and press the keys you want. ⌫ removes it, esc cancels.")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: p.secondary))
                .padding(.bottom, 8)
            ForEach(Array(items.enumerated()), id: \.offset) { index, entry in
                row(menu: entry.menu, title: entry.item.title, index: index)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func row(menu: String, title: String, index: Int) -> some View {
        let p = model.palette
        let override = model.config.keyboardShortcuts[title]
        let shown: String = {
            if let override { return ShortcutSpec(override)?.display ?? "None" }
            return MainMenu.defaultShortcut(of: title) ?? "—"
        }()
        let conflict = override.flatMap(ShortcutSpec.init).flatMap { spec in
            MainMenu.customizableItems().first { other in
                other.item.title != title && current(of: other.item.title) == spec.display
            }?.item.title
        }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: p.text))
                Text(conflict.map { "Also used by \($0)" } ?? menu)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(nsColor: conflict == nil ? p.hint : p.error))
            }
            Spacer()
            if override != nil {
                Button("Reset") { set(title, nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(nsColor: p.accent))
            }
            Button {
                recording == title ? stopRecording() : startRecording(title)
            } label: {
                Text(recording == title ? "Press keys…" : shown)
                    .font(.system(size: 12, weight: .medium, design: recording == title ? .default : .monospaced))
                    .foregroundColor(Color(nsColor: recording == title ? p.accent : p.text))
                    .frame(minWidth: 96)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: recording == title ? p.highlight : p.surface2)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: index % 2 == 0 ? p.surface1 : .clear))
    }

    /// What a command's shortcut is right now (override, else built-in), as displayed.
    private func current(of title: String) -> String? {
        if let override = model.config.keyboardShortcuts[title] { return ShortcutSpec(override)?.display }
        return MainMenu.defaultShortcut(of: title)
    }

    private func set(_ title: String, _ value: String?) {
        var shortcuts = model.config.keyboardShortcuts
        shortcuts[title] = value
        model.set("keyboardShortcuts", shortcuts.isEmpty ? nil : shortcuts)
    }

    private func startRecording(_ title: String) {
        stopRecording()
        recording = title
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if event.keyCode == 53, plain {
                stopRecording()
            } else if event.keyCode == 51, plain {
                set(title, "none")
                stopRecording()
            } else if let spec = MainMenu.spec(from: event) {
                set(title, spec.text)
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }
}
