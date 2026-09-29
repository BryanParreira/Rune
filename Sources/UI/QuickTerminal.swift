import AppKit
import Combine
import RuneKit

/// A terminal that slides down from the top of the screen on the global hotkey, over any
/// app (full-screen ones included), and slides away again. It keeps its own shell between
/// uses; focus goes back to the app that was in front.
final class QuickTerminalController: NSObject, NSWindowDelegate {
    static let shared = QuickTerminalController()

    /// Share of the screen's height the panel takes.
    private static let heightFraction: CGFloat = 0.42

    private var panel: QuickTerminalPanel?
    private var session: TerminalSession?
    private var previousApp: NSRunningApplication?
    private var configObserver: AnyCancellable?
    private var isAnimating = false

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(store: ConfigStore) {
        guard !isAnimating else { return }
        if let panel, panel.isVisible, panel.isKeyWindow {
            hide()
        } else {
            show(store: store)
        }
    }

    // MARK: Showing and hiding

    private func show(store: ConfigStore) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = round(visible.height * Self.heightFraction)
        let target = NSRect(x: visible.minX, y: visible.maxY - height, width: visible.width, height: height)

        let panel = self.panel ?? makePanel(store: store)
        self.panel = panel
        let snapshot = store.snapshot
        panel.appearance = NSAppearance(named: snapshot.theme.isLight ? .aqua : .darkAqua)
        panel.backgroundColor = snapshot.theme.background.nsColor

        if session == nil || session?.state != .running {
            startSession(in: panel, store: store, size: target.size)
        }

        if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        // Slide in from just above the screen's top edge.
        panel.setFrame(target.offsetBy(dx: 0, dy: height), display: false)
        panel.alphaValue = 0
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        session?.focus()
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.isAnimating = false
            self?.session?.focus()
        })
    }

    func hide() {
        guard let panel, panel.isVisible, !isAnimating else { return }
        isAnimating = true
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: frame.height), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isAnimating = false
            // Back to what the user was doing, unless that was another Rune window.
            if let previous = self?.previousApp, !previous.isTerminated {
                previous.activate()
            }
            self?.previousApp = nil
        })
    }

    /// Clicking another app puts the Quick Terminal away.
    func windowDidResignKey(_ notification: Notification) {
        guard let panel, panel.isVisible, !isAnimating else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.keyWindow !== panel, !(NSApp.keyWindow?.sheetParent === panel) else { return }
            if !NSApp.isActive { self.hide() }
        }
    }

    // MARK: Building

    private func makePanel(store: ConfigStore) -> QuickTerminalPanel {
        let panel = QuickTerminalPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                       styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.delegate = self
        configObserver = store.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak panel] snapshot in
                self?.session?.apply(snapshot)
                panel?.backgroundColor = snapshot.theme.background.nsColor
                panel?.appearance = NSAppearance(named: snapshot.theme.isLight ? .aqua : .darkAqua)
            }
        return panel
    }

    private func startSession(in panel: QuickTerminalPanel, store: ConfigStore, size: NSSize) {
        session?.closeContent()
        let directory = RecentDirectories.shared.paths.first ?? NSHomeDirectory()
        let session = SessionPool.shared.take(snapshot: store.snapshot, directory: directory)
            ?? TerminalSession(snapshot: store.snapshot, directory: directory)
        session.onRequestClose = { [weak self] in
            // The shell exited: start fresh next time.
            self?.hide()
            self?.session = nil
        }
        session.view.dismissWelcomeForSession()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        container.addSubview(session.view)
        // A hairline along the bottom edge separates it from the app underneath.
        let line = NSView(frame: NSRect(x: 0, y: 0, width: size.width, height: 1))
        line.wantsLayer = true
        line.layer?.backgroundColor = ChromePalette(theme: store.snapshot.theme).outline.cgColor
        line.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(line)
        panel.contentView = container
        panel.setContentSize(size)
        container.layoutSubtreeIfNeeded()
        if session.state == .notStarted { session.start() }
        self.session = session
    }
}

/// Borderless panels can't become key by default; this one needs the keyboard.
final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
