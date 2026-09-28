import AppKit
import SwiftUI

struct TabItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    /// A file preview that the next clicked file will replace (shown in italics).
    var isPreview = false
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
                    title: tab.title,
                    italic: tab.isPreview,
                    isSelected: tab.id == model.selectedID,
                    palette: model.palette,
                    onSelect: { model.onSelect(tab.id) },
                    onClose: { model.onClose(tab.id) }
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
private struct TabSegment: View {
    let title: String
    let italic: Bool
    let isSelected: Bool
    let palette: ChromePalette
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13))
                .italic(italic)
                .foregroundColor(Color(nsColor: isSelected || hovering ? palette.foreground : palette.secondary))
                .lineLimit(1)
                .truncationMode(.head)
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
        .frame(minWidth: 90, idealWidth: 200, maxWidth: 200, maxHeight: .infinity)
        .background(Color(nsColor: isSelected ? palette.tabSelected : (hovering ? palette.tabHover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(title)
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
