import AppKit
import RuneKit

/// Draws block chrome over the single terminal grid: separators, failed-block tint and flag
/// pole, a context line (cwd · branch) and duration in each block's spacer row, hover and
/// selection highlights, and hover action buttons.
final class BlockOverlayView: NSView {
    weak var sessionView: SessionView?
    var palette: ChromePalette?
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    private var hoveredBlockID: Int?
    private var lastMouseLocation: NSPoint?
    private let actionBar = BlockActionBar()

    // Scroll indicator: thin thumb on the right that appears while scrolling and fades out.
    private var indicatorAlpha: CGFloat = 0
    private var indicatorFade: Timer?
    private var draggingThumb = false
    private var dragOffset: CGFloat = 0
    private var hoveringIndicator = false

    static let flagPoleWidth: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        actionBar.isHidden = true
        addSubview(actionBar)
        actionBar.onAction = { [weak self] action in self?.perform(action) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Only the action bar and the scroll indicator take clicks; everything else falls
    /// through to the terminal.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !actionBar.isHidden, actionBar.frame.contains(local) { return super.hitTest(point) }
        if let track = indicatorTrack(), NSRect(x: track.maxX - 14, y: track.minY, width: 16, height: track.height).contains(local) {
            return self
        }
        return nil
    }

    // MARK: - Scroll indicator

    /// Track rect (flipped overlay coordinates) and scroll metrics, or nil if nothing to scroll.
    private func indicatorTrack() -> NSRect? {
        guard let session = sessionView?.session, session.mode != .fullscreenApp else { return nil }
        let terminal = session.terminalView.getTerminal()
        guard session.geometry.lineCount > terminal.rows else { return nil }
        // The terminal can extend below the visible area (hidden blank rows); use what shows.
        let frame = session.terminalView.frame.intersection(bounds)
        guard frame.height > 8 else { return nil }
        return NSRect(x: bounds.maxX - 10, y: frame.minY + 2, width: 6, height: frame.height - 4)
    }

    private func thumbRect(in track: NSRect) -> NSRect? {
        guard let session = sessionView?.session else { return nil }
        let terminal = session.terminalView.getTerminal()
        let total = CGFloat(session.geometry.lineCount)
        let rows = CGFloat(terminal.rows)
        let maxTop = max(1, total - rows)
        let height = max(28, track.height * rows / total)
        let progress = min(1, max(0, CGFloat(terminal.getTopVisibleRow()) / maxTop))
        return NSRect(x: track.minX, y: track.minY + (track.height - height) * progress, width: track.width, height: height)
    }

    func flashScrollIndicator() {
        guard indicatorTrack() != nil else { return }
        indicatorAlpha = 1
        needsDisplay = true
        scheduleIndicatorFade()
    }

    private func scheduleIndicatorFade() {
        indicatorFade?.invalidate()
        guard !draggingThumb, !hoveringIndicator else { return }
        indicatorFade = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.indicatorFade = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.indicatorAlpha -= 0.1
                if self.indicatorAlpha <= 0 { self.indicatorAlpha = 0; timer.invalidate() }
                self.needsDisplay = true
            }
        }
    }

    private func drawScrollIndicator(palette: ChromePalette) {
        guard indicatorAlpha > 0, let track = indicatorTrack(), let thumb = thumbRect(in: track) else { return }
        let wide = draggingThumb || hoveringIndicator
        let rect = wide ? thumb.insetBy(dx: -1.5, dy: 0) : thumb.insetBy(dx: 0.5, dy: 0)
        palette.foreground.withAlphaComponent((wide ? 0.45 : 0.28) * indicatorAlpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let track = indicatorTrack(), let thumb = thumbRect(in: track), let session = sessionView?.session else { return }
        let point = convert(event.locationInWindow, from: nil)
        draggingThumb = true
        indicatorAlpha = 1
        if thumb.insetBy(dx: -6, dy: 0).contains(point) {
            dragOffset = point.y - thumb.minY
        } else {
            // Click in the track: jump so the thumb centers on the click.
            dragOffset = thumb.height / 2
            scroll(session: session, thumbTop: point.y - dragOffset, track: track, thumbHeight: thumb.height)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingThumb, let track = indicatorTrack(), let thumb = thumbRect(in: track), let session = sessionView?.session else { return }
        let point = convert(event.locationInWindow, from: nil)
        scroll(session: session, thumbTop: point.y - dragOffset, track: track, thumbHeight: thumb.height)
    }

    override func mouseUp(with event: NSEvent) {
        draggingThumb = false
        scheduleIndicatorFade()
        needsDisplay = true
    }

    private func scroll(session: TerminalSession, thumbTop: CGFloat, track: NSRect, thumbHeight: CGFloat) {
        let terminal = session.terminalView.getTerminal()
        let maxTop = max(0, session.geometry.lineCount - terminal.rows)
        let usable = max(1, track.height - thumbHeight)
        let progress = min(1, max(0, (thumbTop - track.minY) / usable))
        session.terminalView.scrollTo(row: Int((progress * CGFloat(maxTop)).rounded()))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        // Wheel over the indicator strip scrolls the terminal as usual.
        sessionView?.session?.terminalView.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        lastMouseLocation = convert(event.locationInWindow, from: nil)
        updateIndicatorHover()
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        lastMouseLocation = nil
        updateIndicatorHover()
        refreshHover()
    }

    private func updateIndicatorHover() {
        let over: Bool
        if let point = lastMouseLocation, let track = indicatorTrack() {
            over = NSRect(x: track.maxX - 14, y: track.minY, width: 16, height: track.height).contains(point)
        } else {
            over = false
        }
        guard over != hoveringIndicator else { return }
        hoveringIndicator = over
        if over {
            indicatorFade?.invalidate()
            indicatorAlpha = 1
        } else {
            scheduleIndicatorFade()
        }
        needsDisplay = true
    }

    // MARK: - Geometry

    private struct BlockFrame {
        let block: Block
        let rect: NSRect
        let headerRect: NSRect
    }

    private func visibleBlockFrames() -> [BlockFrame] {
        guard let session = sessionView?.session, session.mode != .fullscreenApp else { return [] }
        let terminalView = session.terminalView
        let geometry = session.geometry
        let cellHeight = geometry.cellHeight
        guard cellHeight > 0 else { return [] }
        let current = geometry.cursorPosition.row
        let top = geometry.topVisibleRow
        let bottom = top + session.terminalView.getTerminal().rows

        var frames: [BlockFrame] = []
        for block in session.tracker.blocks {
            let last = block.lastRow(currentRow: current)
            guard last >= top, block.headerRow <= bottom else { continue }
            // Terminal view coordinates (not flipped) → overlay coordinates (flipped).
            let topInTerminal = NSPoint(x: 0, y: geometry.topY(ofRow: block.headerRow))
            let bottomInTerminal = NSPoint(x: 0, y: geometry.topY(ofRow: last + 1))
            let y0 = convert(topInTerminal, from: terminalView).y
            let y1 = convert(bottomInTerminal, from: terminalView).y
            let rect = NSRect(x: 0, y: y0, width: bounds.width, height: max(cellHeight, y1 - y0))
            let header = NSRect(x: 0, y: y0, width: bounds.width, height: cellHeight)
            frames.append(BlockFrame(block: block, rect: rect, headerRect: header))
        }
        return frames
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let palette, let session = sessionView?.session else { return }
        let terminalFrame = session.terminalView.frame
        let clip = NSRect(x: 0, y: terminalFrame.minY, width: bounds.width, height: terminalFrame.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: clip).addClip()

        let frames = visibleBlockFrames()
        let contextFont = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 1), weight: .regular)

        for (index, frame) in frames.enumerated() {
            let block = frame.block

            if block.isFailed {
                palette.error.withAlphaComponent(0.10).setFill()
                frame.rect.fill()
            }
            if block.id == session.selectedBlockID {
                palette.accent.withAlphaComponent(0.14).setFill()
                frame.rect.fill()
                palette.accent.withAlphaComponent(0.7).setStroke()
                let border = NSBezierPath(rect: frame.rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                border.stroke()
            } else if block.id == hoveredBlockID {
                palette.foreground.withAlphaComponent(0.03).setFill()
                frame.rect.fill()
            }
            if block.isFailed {
                palette.error.setFill()
                NSRect(x: 0, y: frame.rect.minY, width: Self.flagPoleWidth, height: frame.rect.height).fill()
            }

            // Separator above every block except one that starts at the very top.
            if index > 0 || frame.rect.minY > terminalFrame.minY + 1 {
                palette.outline.setFill()
                NSRect(x: 0, y: frame.rect.minY.rounded(.down), width: bounds.width, height: 1).fill()
            }

            drawHeader(block, in: frame.headerRect, palette: palette, font: contextFont, session: session,
                       reserveForActions: block.id == hoveredBlockID)
        }
        NSGraphicsContext.restoreGraphicsState()
        drawScrollIndicator(palette: palette)
    }

    private func drawHeader(_ block: Block, in rect: NSRect, palette: ChromePalette, font: NSFont,
                            session: TerminalSession, reserveForActions: Bool) {
        let left = session.terminalView.frame.minX
        let right = bounds.width - session.terminalView.frame.minX

        // Context: cwd (and host if remote later).
        let context = TabTitle.abbreviate(path: block.cwd, home: NSHomeDirectory())
        if !context.isEmpty, !session.config.honorPrompt, !session.typeInShell {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.hint]
            let size = (context as NSString).size(withAttributes: attrs)
            let origin = NSPoint(x: left, y: rect.midY - size.height / 2)
            (context as NSString).draw(at: origin, withAttributes: attrs)
        }

        guard !reserveForActions else { return }
        var status = Self.format(duration: block.duration())
        if block.isFailed, let code = block.exitCode { status = "exit \(code)  ·  " + status }
        if block.state == .running { status = "running  ·  " + status }
        let color = block.isFailed ? palette.error.withAlphaComponent(0.9) : palette.hint
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (status as NSString).size(withAttributes: attrs)
        (status as NSString).draw(at: NSPoint(x: right - size.width, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    static func format(duration: TimeInterval) -> String {
        if duration < 1 { return String(format: "%.0fms", max(0, duration * 1000)) }
        if duration < 60 { return String(format: "%.2fs", duration) }
        let total = Int(duration.rounded())
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }

    // MARK: - Hover

    func refreshHover() {
        let frames = visibleBlockFrames()
        var hovered: BlockFrame?
        if let point = lastMouseLocation {
            hovered = frames.last { $0.rect.contains(point) }
        }
        let newID = hovered?.block.id
        if newID != hoveredBlockID {
            hoveredBlockID = newID
            needsDisplay = true
        }
        guard let hovered, let palette, let session = sessionView?.session else {
            actionBar.isHidden = true
            return
        }
        actionBar.palette = palette
        actionBar.canRerun = session.mode == .editor
        actionBar.showsExplain = hovered.block.isFailed && AIService.shared.isEnabled
        let size = actionBar.fittingSize
        let right = bounds.width - session.terminalView.frame.minX + 6
        let y = max(hovered.headerRect.minY, session.terminalView.frame.minY)
        actionBar.frame = NSRect(x: right - size.width, y: y + (hovered.headerRect.height - size.height) / 2,
                                 width: size.width, height: size.height)
        actionBar.isHidden = false
    }

    private func perform(_ action: BlockActionBar.Action) {
        guard let session = sessionView?.session, let id = hoveredBlockID, let block = session.tracker.block(id: id) else { return }
        switch action {
        case .copyCommand: session.copyCommand(block)
        case .copyOutput: session.copyOutput(block)
        case .rerun: session.rerun(block)
        case .explain: session.explain(block)
        }
    }
}

/// Small floating bar with block actions.
final class BlockActionBar: NSView {
    enum Action { case copyCommand, copyOutput, rerun, explain }

    var onAction: ((Action) -> Void)?
    var palette: ChromePalette? { didSet { restyle() } }
    var canRerun = true { didSet { rerunButton.isEnabled = canRerun } }
    var showsExplain = false { didSet { explainButton.isHidden = !showsExplain } }

    private let stack = NSStackView()
    private lazy var copyCommandButton = makeButton("text.cursor", "Copy command", .copyCommand)
    private lazy var copyOutputButton = makeButton("doc.on.doc", "Copy output", .copyOutput)
    private lazy var rerunButton = makeButton("arrow.clockwise", "Re-run", .rerun)
    private lazy var explainButton = makeButton("sparkle", "Explain this error with AI", .explain)

    static let height: CGFloat = 24

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [explainButton, copyCommandButton, copyOutputButton, rerunButton].forEach(stack.addArrangedSubview)
        explainButton.isHidden = true
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func makeButton(_ symbol: String, _ tip: String, _ action: Action) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
        let button = HoverIconButton(image: image, target: nil, action: nil)
        button.toolTip = tip
        button.onClick = { [weak self] in self?.onAction?(action) }
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        return button
    }

    private func restyle() {
        guard let palette else { return }
        layer?.backgroundColor = palette.surface2.cgColor
        layer?.borderColor = palette.outline.cgColor
        for case let button as HoverIconButton in stack.arrangedSubviews {
            button.palette = palette
        }
    }
}

/// Borderless SF Symbol button with a hover background.
final class HoverIconButton: NSButton {
    var onClick: (() -> Void)?
    var palette: ChromePalette? { didSet { updateColors() } }
    private var hovering = false { didSet { updateColors() } }

    convenience init(image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        self.target = self
        self.action = #selector(clicked)
    }

    @objc private func clicked() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateColors() {
        guard let palette else { return }
        contentTintColor = isEnabled ? (hovering ? palette.text : palette.secondary) : palette.disabled
        layer?.backgroundColor = hovering && isEnabled ? palette.foreground.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
    }

    override var isEnabled: Bool {
        didSet { updateColors() }
    }
}
