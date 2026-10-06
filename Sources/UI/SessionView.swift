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
    private let remoteModel = RemoteOfferModel()
    private lazy var remoteHost: NSHostingView<RemoteOfferBar> = {
        let host = NSHostingView(rootView: RemoteOfferBar(model: remoteModel))
        host.sizingOptions = [.intrinsicContentSize]
        host.safeAreaRegions = []
        return host
    }()
    private var filterHost: NSHostingView<BlockFilterView>?
    let finder = OutputFindModel()
    private lazy var findHost: NSHostingView<OutputFindBar> = {
        let host = NSHostingView(rootView: OutputFindBar(model: finder))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.isHidden = true
        addSubview(host, positioned: .above, relativeTo: nil)
        return host
    }()
    private lazy var completionHost: NSHostingView<CompletionMenuView> = {
        let host = NSHostingView(rootView: CompletionMenuView(model: inputArea.completionMenu) { [weak self] index in
            self?.inputArea.acceptCompletion(index)
        })
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.isHidden = true
        addSubview(host, positioned: .above, relativeTo: nil)
        return host
    }()
    private var cancellables: Set<AnyCancellable> = []
    private var snapshot: ConfigSnapshot?

    init(terminalView: RuneTerminalView) {
        self.terminalView = terminalView
        terminalContainer = TerminalContainerView(terminalView: terminalView)
        overlay = BlockOverlayView()
        inputArea = InputAreaView()
        welcomeHost = NSHostingView(rootView: WelcomePanel(model: welcomeModel))
        super.init(frame: .zero)

        #if DEBUG
        Self.liveCount += 1
        #endif
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

        remoteModel.onEnable = { [weak self] always in self?.session?.acceptRemoteOffer(always: always) }
        remoteModel.onDecline = { [weak self] in
            self?.remoteModel.kind = nil
            self?.session?.declineRemoteOffer()
        }
        waterfallSpacer.isHidden = true
        for view in [terminalContainer, welcomeHost, aiHost, remoteHost, inputArea, waterfallSpacer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Panels wrap or truncate in a narrow pane instead of widening the window.
        for host in [welcomeHost, aiHost, remoteHost] as [NSView] {
            host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        terminalContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalContainer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        welcomeHost.setContentHuggingPriority(.required, for: .vertical)
        aiHost.setContentHuggingPriority(.required, for: .vertical)
        aiHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        inputArea.setContentHuggingPriority(.required, for: .vertical)
        remoteHost.setContentHuggingPriority(.required, for: .vertical)
        inputArea.setContentCompressionResistancePriority(.required, for: .vertical)
        waterfallSpacer.setContentHuggingPriority(.init(1), for: .vertical)
        waterfallSpacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        waterfallHeight.priority = .init(999)

        addSubview(stack)
        // The AI card never takes more than ~45% of the tab; output always keeps room.
        let aiCap = aiHost.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.45)
        aiCap.priority = .required
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

    // MARK: Bell and hover

    /// The "flash" bell: a quick wash of the accent color over the pane.
    func flash() {
        guard let layer, let palette = overlay.palette else { return }
        let wash = CALayer()
        wash.frame = layer.bounds
        wash.backgroundColor = palette.accent.withAlphaComponent(0.12).cgColor
        wash.opacity = 0
        layer.addSublayer(wash)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.25, 1]
        fade.duration = 0.25
        CATransaction.begin()
        CATransaction.setCompletionBlock { wash.removeFromSuperlayer() }
        wash.add(fade, forKey: "flash")
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    /// "Focus pane on hover": the pane under the pointer takes the keyboard (splits only).
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let session, session.config.focusPaneOnHover, let window,
              superview is PaneSplitView || superview?.superview is PaneSplitView,
              !isDescendantOfFirstResponder(in: window) else { return }
        session.focus()
    }

    private func isDescendantOfFirstResponder(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    // MARK: Waterfall input

    /// Keeps output from shrinking away in the usual layout.
    private lazy var terminalFloor = terminalContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 90)
    /// "waterfall" input position: the output area is only as tall as the rows in use, so the
    /// input sits right under the last output (moving down as it grows) with this empty space
    /// below it. The terminal keeps its full size inside (no resize, no reflow).
    private let waterfallSpacer = NSView()
    private lazy var waterfallHeight = terminalContainer.heightAnchor.constraint(equalToConstant: 0)
    private var waterfall = false

    private func setWaterfall(_ on: Bool) {
        guard on != waterfall else { return }
        waterfall = on
        updateWaterfall()
    }

    /// Sizes the output area to the rows in use, or gives it the whole pane (when the output
    /// fills it, a full-screen program runs, or waterfall is off).
    private func updateWaterfall() {
        let rows = waterfall ? session?.usedScreenRows : nil
        let shrink = rows != nil && bounds.height > 0
        if waterfallSpacer.isHidden == shrink { waterfallSpacer.isHidden = !shrink }
        if terminalFloor.isActive == shrink { terminalFloor.isActive = !shrink }
        if waterfallHeight.isActive != shrink { waterfallHeight.isActive = shrink }
        guard shrink, let rows, let session else { return }
        let padding = terminalContainer.padding
        let height = min(bounds.height, padding.top + padding.bottom + CGFloat(rows) * session.geometry.cellHeight)
        if abs(waterfallHeight.constant - height) > 0.5 { waterfallHeight.constant = height }
    }

    #if DEBUG
    static var liveCount = 0
    #endif

    deinit {
        chromeLink?.invalidate()
        #if DEBUG
        Self.liveCount -= 1
        #endif
    }

    override var isFlipped: Bool { true }

    /// The find bar floats at the top right of the output.
    func layoutFindBar() {
        guard finder.isOpen else {
            if findHost.superview != nil { findHost.isHidden = true }
            return
        }
        let output = convert(terminalContainer.bounds, from: terminalContainer)
        let width = min(460, output.width - 24)
        findHost.frame = NSRect(x: output.maxX - width - 12, y: output.minY + 8, width: width, height: 34)
        findHost.isHidden = false
    }

    override func layout() {
        // Before the stack resizes the container, so the terminal's size (and the PTY's) only
        // changes when the pane itself does.
        terminalContainer.paneHeight = bounds.height
        super.layout()
        updateAILayout()
        if finder.isOpen { layoutFindBar() }
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
        remoteModel.palette = palette
        remoteModel.horizontalPadding = CGFloat(config.paddingX)
        welcomeModel.fontSize = CGFloat(config.fontSize)
        welcomeModel.horizontalPadding = CGFloat(config.paddingX)
        inputArea.apply(snapshot: snapshot, palette: palette)
        overlay.palette = palette
        finder.palette = palette
        overlay.font = snapshot.font
        setWaterfall(config.inputPosition == "waterfall")
        rebuildAIPanel()
        updateVisibility()
        blocksDidChange()
    }

    /// Fires on the display's refresh (60/120 Hz) while block chrome needs refreshing, then
    /// pauses itself.
    private var chromeLink: CADisplayLink?

    /// Coalesces overlay updates: heavy output calls this for every chunk, but block chrome is
    /// recomputed at most once per display frame, in step with the text instead of trailing it.
    func blocksDidChange() {
        if chromeLink == nil {
            let link = displayLink(target: WeakDisplayTarget(self), selector: #selector(WeakDisplayTarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            chromeLink = link
        }
        chromeLink?.isPaused = false
    }

    /// Brings block chrome up to date now (also called when the terminal redraws its text).
    func refreshBlockChrome() {
        chromeLink?.isPaused = true
        // Chrome for output the terminal hasn't drawn yet would show a frame before its text:
        // redraw the text now; that calls back here (onTextRedraw) for the chrome.
        if terminalView.hasUndrawnOutput {
            terminalView.setNeedsDisplay(terminalView.bounds)
            return
        }
        session?.updateBottomTrim()
        updateWaterfall()
        overlay.needsDisplay = true
        overlay.refreshHover()
    }

    /// The viewport moved: redraw the chrome in the same pass as the scrolled text so block
    /// backgrounds and headers never lag behind it.
    func viewportDidScroll() {
        overlay.needsDisplay = true
        blocksDidChange()
    }

    func contextDidChange() {
        guard let session else { return }
        inputArea.updateContext(directory: session.displayDirectory, branch: session.isRemote ? nil : session.gitBranch)
        // Through the frame-synced path, so headers never change ahead of the text.
        blocksDidChange()
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

    func showRemoteOffer(host: String) {
        remoteModel.kind = .offer(host)
    }

    func showRemoteFailure(host: String) {
        remoteModel.kind = .failed(host)
    }

    func hideRemoteOffer() {
        remoteModel.kind = nil
    }

    /// "Filter Output…": the block's lines matching a query, over the output area.
    func showFilter(command: String, output: String) {
        closeFilter()
        guard let snapshot else { return }
        let model = BlockFilterModel(command: command, output: output, palette: ChromePalette(theme: snapshot.theme)) { [weak self] in
            self?.closeFilter()
        }
        let host = NSHostingView(rootView: BlockFilterView(model: model, fontSize: CGFloat(snapshot.config.fontSize)))
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
        ])
        filterHost = host
    }

    func closeFilter() {
        filterHost?.removeFromSuperview()
        filterHost = nil
        focusPreferredResponder()
    }

    /// Places the completion menu just above the input, under the caret, over the output
    /// (nothing moves or resizes), or hides it.
    func layoutCompletionMenu() {
        let menu = inputArea.completionMenu
        guard menu.isOpen, !inputArea.isHidden, let window else {
            if completionHost.superview != nil { completionHost.isHidden = true }
            return
        }
        let editor = inputArea.editor
        // The input lives in the stack view, whose coordinates aren't flipped like ours.
        let input = convert(inputArea.bounds, from: inputArea)
        var caretX = input.minX + CGFloat(snapshot?.config.paddingX ?? 16)
        let screenRect = editor.firstRect(forCharacterRange: NSRange(location: menu.range.location, length: 0), actualRange: nil)
        if screenRect != .zero {
            caretX = convert(window.convertFromScreen(screenRect), from: nil).minX
        }
        let size = NSSize(width: min(menu.width, bounds.width - 16), height: menu.height)
        let x = min(max(8, caretX - 14), bounds.width - size.width - 8)
        let y = max(4, input.minY - size.height - 4)
        completionHost.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        completionHost.isHidden = false
    }

    /// Bytes typed into the terminal view while the editor owns input.
    func redirectToEditor(_ data: ArraySlice<UInt8>) {
        inputArea.receiveRedirected(data)
    }
}

/// A display link retains its target; this keeps it from retaining the session view.
private final class WeakDisplayTarget: NSObject {
    weak var view: SessionView?

    init(_ view: SessionView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.refreshBlockChrome()
    }
}
