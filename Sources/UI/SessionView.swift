import AppKit
import Combine
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
    let conversation = AIConversation()
    private let aiHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let aiLayout = AIPanelLayout()
    private var cancellables: Set<AnyCancellable> = []
    private var snapshot: ConfigSnapshot?

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
        aiHost.sizingOptions = [.intrinsicContentSize]
        aiHost.safeAreaRegions = []
        aiHost.isHidden = true
        conversation.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateVisibility() } }
            .store(in: &cancellables)

        for view in [terminalContainer, welcomeHost, aiHost, inputArea] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        terminalContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        welcomeHost.setContentHuggingPriority(.required, for: .vertical)
        aiHost.setContentHuggingPriority(.required, for: .vertical)
        aiHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        inputArea.setContentHuggingPriority(.required, for: .vertical)
        inputArea.setContentCompressionResistancePriority(.required, for: .vertical)

        addSubview(stack)
        // The AI card never takes more than ~45% of the tab; output always keeps room.
        let aiCap = aiHost.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.45)
        aiCap.priority = .required
        let terminalFloor = terminalContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
        terminalFloor.priority = .defaultHigh
        NSLayoutConstraint.activate([
            aiCap,
            terminalFloor,
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

    override func layout() {
        super.layout()
        updateAILayout()
    }

    /// The AI card may take up to 45% of the pane, minus what the output and input need;
    /// its header, padding and buttons take ~76pt of that and the answer scrolls in the rest.
    private func updateAILayout() {
        let cap = min(bounds.height * 0.45, bounds.height - inputArea.fittingSize.height - 90)
        let answer = max(48, floor(cap - 76))
        if abs(aiLayout.maxAnswerHeight - answer) > 0.5 { aiLayout.maxAnswerHeight = answer }
    }

    // MARK: - Updates from the session

    func apply(_ snapshot: ConfigSnapshot) {
        self.snapshot = snapshot
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
        rebuildAIPanel()
        updateVisibility()
        blocksDidChange()
    }

    private var blockRefreshPending = false

    /// Coalesces overlay updates: heavy output calls this for every chunk, but the overlay
    /// only needs to be recomputed once per frame (~30 fps is plenty for chrome).
    func blocksDidChange() {
        guard !blockRefreshPending else { return }
        blockRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.blockRefreshPending = false
            self.session?.updateBottomTrim()
            self.overlay.needsDisplay = true
            self.overlay.refreshHover()
        }
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
        let aiVisible = conversation.isVisible && mode.editorVisible
        aiHost.isHidden = !aiVisible
        inputArea.aiConversationOpen = aiVisible
        welcomeHost.isHidden = aiVisible || !(mode == .editor && session.config.showWelcome && !welcomeDismissed)
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

    private func rebuildAIPanel() {
        guard let snapshot else { return }
        let palette = ChromePalette(theme: snapshot.theme)
        aiHost.rootView = AnyView(AIPanel(
            conversation: conversation,
            layout: aiLayout,
            palette: palette,
            fontSize: CGFloat(snapshot.config.fontSize),
            horizontalPadding: CGFloat(snapshot.config.paddingX),
            onRun: { [weak self] command in
                self?.session?.submit(command)
            },
            onEdit: { [weak self] command in
                self?.conversation.dismiss()
                self?.inputArea.setText(command)
            },
            onPullModel: { [weak self] model in
                self?.conversation.dismiss()
                self?.session?.onRequestNewTab?("ollama pull \(model)")
            },
            onOpenSettings: {
                NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
            }
        ))
    }

    /// Bytes typed into the terminal view while the editor owns input.
    func redirectToEditor(_ data: ArraySlice<UInt8>) {
        inputArea.receiveRedirected(data)
    }
}
