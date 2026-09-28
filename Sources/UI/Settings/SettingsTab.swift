import AppKit
import Combine
import RuneKit
import SwiftUI

/// Settings, shown as a tab in the main window. Every control writes straight to config.json
/// (or the synced copy), so the file stays the single source of truth and edits made in a text
/// editor show up here live.
final class SettingsTab: TabContent {
    let id = UUID()
    let title = "Settings"
    let contentView: NSView
    private let model: SettingsModel

    init(store: ConfigStore) {
        model = SettingsModel(store: store)
        let host = NSHostingView(rootView: SettingsView(model: model))
        host.safeAreaRegions = []
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
        store.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] in self?.snapshot = $0 }.store(in: &cancellables)
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
    }

    func isOverridden(_ key: String) -> Bool { store.hasMachineOverride(key: key) }
    func clearOverride(_ key: String) { store.clearMachineOverride(key: key) }

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
            return ["Theme", "Font", "Font size", "Line height", "Cursor", "Blinking cursor", "Padding", "Nerd Font", "icons", "colors"]
        case .terminal:
            return ["Shell", "Show shell prompt", "PS1", "Starship", "Scrollback", "Option key", "Meta"]
        case .input:
            return ["New session panel", "welcome", "editor", "history", "completion"]
        case .keyboard:
            return KeyboardShortcut.all.map(\.action) + ["shortcuts", "keybindings"]
        case .sync:
            return ["Sync folder", "iCloud", "dotfiles", "This Mac only", "machine", "hosts", "per-machine"]
        case .about:
            return ["Version", "License", "Config file", "local-first", "privacy", "telemetry"]
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
        .init(action: "Clear input / interrupt running command", keys: ["⌃", "C"]),
        .init(action: "Select previous block", keys: ["⌘", "↑"]),
        .init(action: "Select next block", keys: ["⌘", "↓"]),
        .init(action: "Clear screen", keys: ["⌘", "K"]),
        .init(action: "New tab", keys: ["⌘", "T"]),
        .init(action: "Close tab", keys: ["⌘", "W"]),
        .init(action: "Switch to tab 1–8 / last tab", keys: ["⌘", "1…9"]),
        .init(action: "Next / previous tab", keys: ["⌘", "⇧", "] ["]),
        .init(action: "New window", keys: ["⌘", "N"]),
        .init(action: "Settings", keys: ["⌘", ","]),
        .init(action: "Find", keys: ["⌘", "F"]),
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
                Rectangle().fill(Color(nsColor: palette.outline)).frame(width: 1)
                ScrollView {
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
                    .frame(maxWidth: .infinity)
                }
            }
        }
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
                .foregroundColor(selected ? .white : Color(nsColor: hovering ? palette.text : palette.secondary.withAlphaComponent(0.8)))
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
            .font(.system(size: 23, weight: .bold))
            .foregroundColor(Color(nsColor: palette.text))
            .padding(.bottom, 15)
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
            SettingRow(model: model, title: "Theme", key: "theme", detail: "Add your own as themes/<name>.json in the config folder.") {
                DropdownField(selection: model.binding("theme", { $0.theme }), options: model.themes, label: { $0 }, palette: p)
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
        }
    }
}

struct InputPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Input", palette: p)
            SettingRow(model: model, title: "Show “New session” panel", key: "showWelcome", detail: "Shortcut tips above the input editor in new tabs.") {
                SwitchControl(isOn: model.binding("showWelcome", { $0.showWelcome }))
            }
            SettingRow(model: model, title: "Command history", detail: "Up/Down cycles through ~/.zsh_history plus commands run in Rune.") {
                EmptyView()
            }
            SettingRow(model: model, title: "Tab completion", detail: "Completes files and folders relative to the current directory.") {
                EmptyView()
            }
        }
    }
}

struct KeyboardPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let p = model.palette
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(text: "Keyboard shortcuts", palette: p)
            let rows = KeyboardShortcut.all.filter { model.matches($0.action) || model.matches("shortcuts") }
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
            SettingRow(model: model, title: "License", detail: "MIT. Terminal emulation by SwiftTerm (MIT).") {
                EmptyView()
            }
        }
    }
}
