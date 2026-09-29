import AppKit
import RuneKit
import SwiftUI

struct TabItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    /// A file preview that the next clicked file will replace (shown in italics).
    var isPreview = false
    var color: TabColor?
    /// The name the user gave the tab, if any.
    var customTitle: String?
    /// Terminal tabs can be renamed and colored.
    var canStyle = false
}

extension TabColor {
    /// Muted, warm tones that sit well on Paper and on the dark themes.
    func nsColor(light: Bool) -> NSColor {
        let hex: UInt32
        switch self {
        case .red: hex = light ? 0xC0503A : 0xE07A62
        case .orange: hex = light ? 0xCC7A2A : 0xEFA25C
        case .yellow: hex = light ? 0xB8931C : 0xE6C466
        case .green: hex = light ? 0x4E8A5A : 0x84B795
        case .blue: hex = light ? 0x3B6EA5 : 0x7EA8D8
        case .purple: hex = light ? 0x7A5CA6 : 0xB29DDA
        case .pink: hex = light ? 0xBF5580 : 0xE79BBA
        }
        return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// State shared between the window controller and the SwiftUI tab bar.
final class TabsModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var selectedID: UUID?
    @Published var palette: ChromePalette

    @Published var sidebarVisible = false
    var onToggleSidebar: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onNew: () -> Void = {}
    /// The tab whose name is being edited in place.
    @Published var editingID: UUID?
    /// A new name, or nil to go back to the automatic one.
    var onRename: (UUID, String?) -> Void = { _, _ in }
    var onSetColor: (UUID, TabColor?) -> Void = { _, _ in }
    var onCloseOthers: (UUID) -> Void = { _ in }

    init(palette: ChromePalette) {
        self.palette = palette
    }
}

struct TabBarView: View {
    @ObservedObject var model: TabsModel
    /// Space reserved on the left for the traffic lights.
    let leadingInset: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            SidebarToggle(isOn: model.sidebarVisible, palette: model.palette, action: model.onToggleSidebar)
                .padding(.trailing, 8)
            Divider(palette: model.palette)
            ForEach(model.tabs) { tab in
                TabSegment(
                    tab: tab,
                    isSelected: tab.id == model.selectedID,
                    isEditing: tab.id == model.editingID,
                    hasOthers: model.tabs.count > 1,
                    palette: model.palette,
                    onSelect: { model.onSelect(tab.id) },
                    onClose: { model.onClose(tab.id) },
                    onCloseOthers: { model.onCloseOthers(tab.id) },
                    onStartRename: { if tab.canStyle { model.editingID = tab.id } },
                    onRename: { name in
                        model.editingID = nil
                        if let name, name != tab.title { model.onRename(tab.id, name) }
                    },
                    onSetColor: { model.onSetColor(tab.id, $0) }
                )
                Divider(palette: model.palette)
            }
            HStack(spacing: 2) {
                IconButton(systemName: "plus", size: 14, palette: model.palette, help: "New Tab (⌘T)", action: model.onNew)
                Menu {
                    Button("New Tab") { model.onNew() }
                    Button("New Window") { NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundColor(Color(nsColor: model.palette.secondary))
                .frame(width: 22, height: 28)
            }
            .padding(.leading, 8)
            Spacer(minLength: 0)
            IconButton(systemName: "gearshape", size: 13, palette: model.palette, help: "Settings (⌘,)", action: model.onOpenSettings)
                .padding(.trailing, 10)
        }
        .padding(.leading, leadingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: model.palette.separator)).frame(height: 1)
        }
    }
}

/// Shows/hides the file tree (⌘B).
private struct SidebarToggle: View {
    let isOn: Bool
    let palette: ChromePalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .foregroundColor(Color(nsColor: isOn ? palette.text : (hovering ? palette.text : palette.secondary)))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: isOn ? palette.tabSelected : (hovering ? palette.tabHover : .clear))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Hide file tree (⌘B)" : "Show file tree (⌘B)")
    }
}

private struct Divider: View {
    let palette: ChromePalette
    var body: some View {
        Rectangle().fill(Color(nsColor: palette.separator)).frame(width: 1)
    }
}

/// Flat, full-height tab with a centered title; the close button appears on hover.
/// Double-click renames a terminal tab; right-click has name, color and close actions.
private struct TabSegment: View {
    let tab: TabItem
    let isSelected: Bool
    let isEditing: Bool
    let hasOthers: Bool
    let palette: ChromePalette
    let onSelect: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onStartRename: () -> Void
    /// The typed name ("" resets to the automatic name), or nil when editing was cancelled.
    let onRename: (String?) -> Void
    let onSetColor: (TabColor?) -> Void

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var tint: NSColor? { tab.color?.nsColor(light: palette.isLight) }

    var body: some View {
        ZStack {
            if isEditing {
                TextField("Tab name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color(nsColor: palette.foreground))
                    .focused($fieldFocused)
                    .onSubmit { onRename(draft) }
                    .onKeyPress(.escape) { onRename(nil); return .handled }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused && isEditing { onRename(draft) }
                    }
                    .padding(.horizontal, 14)
                    .onAppear {
                        draft = tab.customTitle ?? tab.title
                        DispatchQueue.main.async { fieldFocused = true }
                    }
            } else {
                HStack(spacing: 6) {
                    if let tint {
                        Circle().fill(Color(nsColor: tint)).frame(width: 7, height: 7)
                    }
                    Text(tab.title)
                        .font(.system(size: 13))
                        .italic(tab.isPreview)
                        .foregroundColor(Color(nsColor: isSelected || hovering ? palette.foreground : palette.secondary))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, 28)
                HStack {
                    Spacer()
                    if hovering {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(nsColor: palette.secondary))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close Tab (⌘W)")
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .frame(minWidth: 90, idealWidth: 200, maxWidth: 200, maxHeight: .infinity)
        .background(background)
        .overlay(alignment: .bottom) {
            if let tint {
                Rectangle().fill(Color(nsColor: tint)).frame(height: isSelected ? 2 : 1.5)
            }
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded(onSelect))
        .simultaneousGesture(TapGesture(count: 2).onEnded(onStartRename))
        .onHover { hovering = $0 }
        .help(tab.canStyle ? "\(tab.title) — double-click to rename" : tab.title)
        .contextMenu { menu }
    }

    private var background: Color {
        if let tint {
            return Color(nsColor: tint.withAlphaComponent(isSelected ? 0.16 : (hovering ? 0.11 : 0.07)))
        }
        return Color(nsColor: isSelected ? palette.tabSelected : (hovering ? palette.tabHover : .clear))
    }

    @ViewBuilder private var menu: some View {
        if tab.canStyle {
            Button("Rename Tab…", action: onStartRename)
            if tab.customTitle != nil {
                Button("Use Automatic Name") { onRename("") }
            }
            Picker("Color", selection: Binding(get: { tab.color }, set: onSetColor)) {
                Text("None").tag(TabColor?.none)
                ForEach(TabColor.allCases, id: \.self) { color in
                    Text(color.displayName).tag(TabColor?.some(color))
                }
            }
            SwiftUI.Divider()
        }
        Button("Close Tab", action: onClose)
        if hasOthers {
            Button("Close Other Tabs", action: onCloseOthers)
        }
    }
}

private struct IconButton: View {
    let systemName: String
    let size: CGFloat
    let palette: ChromePalette
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(Color(nsColor: hovering ? palette.foreground : palette.secondary))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Empty tab-bar space drags the window; double-click zooms like a normal titlebar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" {
                    window.performMiniaturize(nil)
                } else if action != "None" {
                    window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
