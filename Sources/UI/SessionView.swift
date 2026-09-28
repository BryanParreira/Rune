import AppKit
import RuneKit
import SwiftUI

/// Layout of one tab: output blocks on top, then the welcome panel and the input area.
/// Full-screen apps and plain shells get the whole pane.
final class SessionView: NSView {
    weak var session: TerminalSession?

    let terminalView: RuneTerminalView
    let terminalContainer: TerminalContainerView
    let overlay: BlockOverlayView
    let inputArea: InputAreaView
    private let welcomeModel = WelcomeModel()
    private let welcomeHost: NSHostingView<WelcomePanel>
    private let stack = NSStackView()
    private var welcomeDismissed = false

    init(terminalView: RuneTerminalView) {
        self.terminalView = terminalView
        terminalContainer = TerminalContainerView(terminalView: terminalView)
        overlay = BlockOverlayView()
        inputArea = InputAreaView()
        welcomeHost = NSHostingView(rootView: WelcomePanel(model: welcomeModel))
        super.init(frame: .zero)

        overlay.sessionView = self
        terminalContainer.overlay = overlay
        inputArea.sessionView = self
        welcomeHost.sizingOptions = [.intrinsicContentSize]
        welcomeHost.safeAreaRegions = []
        welcomeModel.onDismiss = { [weak self] in self?.dismissWelcomeForSession() }
        welcomeModel.onNeverShow = { [weak self] in
            self?.dismissWelcomeForSession()
            ConfigStore.current?.write(key: "showWelcome", value: false)
        }

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [terminalContainer, welcomeHost, inputArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        terminalContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        welcomeHost.setContentHuggingPriority(.required, for: .vertical)
        inputArea.setContentHuggingPriority(.required, for: .vertical)
        inputArea.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    // MARK: - Updates from the session

    func apply(_ snapshot: ConfigSnapshot) {
        let palette = ChromePalette(theme: snapshot.theme)
        let config = snapshot.config
        wantsLayer = true
        layer?.backgroundColor = palette.background.cgColor
        terminalContainer.background = palette.background
        terminalContainer.padding = NSEdgeInsets(top: config.paddingY, left: config.paddingX, bottom: 10, right: config.paddingX)
        welcomeModel.palette = palette
        welcomeModel.fontSize = CGFloat(config.fontSize)
        welcomeModel.horizontalPadding = CGFloat(config.paddingX)
        inputArea.apply(snapshot: snapshot, palette: palette)
        overlay.palette = palette
        overlay.font = snapshot.font
        updateVisibility()
        blocksDidChange()
    }

    func blocksDidChange() {
        overlay.needsDisplay = true
        overlay.refreshHover()
    }

    func contextDidChange() {
        guard let session else { return }
        inputArea.updateContext(directory: session.currentDirectory, branch: session.gitBranch)
        overlay.needsDisplay = true
    }

    func modeDidChange() {
        updateVisibility()
        focusPreferredResponder()
    }

    func dismissWelcomeForSession() {
        guard !welcomeDismissed else { return }
        welcomeDismissed = true
        updateVisibility()
    }

    private func updateVisibility() {
        guard let session else { return }
        let mode = session.mode
        inputArea.isHidden = !mode.editorVisible
        inputArea.setRunning(mode == .runningCommand, command: session.tracker.blocks.last?.command)
        welcomeHost.isHidden = !(mode == .editor && session.config.showWelcome && !welcomeDismissed)
        overlay.isHidden = mode == .fullscreenApp
        contextDidChange()
    }

    /// Gives keyboard focus to the editor when it owns input, otherwise to the terminal.
    func focusPreferredResponder() {
        guard let window, !isHidden, let session else { return }
        if session.mode == .editor {
            inputArea.focusEditor()
        } else if window.firstResponder !== terminalView {
            window.makeFirstResponder(terminalView)
        }
    }

    /// Bytes typed into the terminal view while the editor owns input.
    func redirectToEditor(_ data: ArraySlice<UInt8>) {
        inputArea.receiveRedirected(data)
    }
}
