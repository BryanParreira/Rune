import AppKit
import RuneKit

/// A terminal tab: one or more sessions arranged in split panes. The pane layout is a tree of
/// `PaneSplitView`s whose leaves are the sessions' views.
final class TerminalTab: TabContent {
    enum Direction { case left, right, up, down }

    let id = UUID()
    private let root = PaneRootView()
    private(set) var sessions: [TerminalSession] = []
    private weak var focused: TerminalSession?
    private var dividerColor: NSColor

    /// The pane that has (or last had) keyboard focus.
    var focusedSession: TerminalSession? {
        if let focused, sessions.contains(where: { $0 === focused }) { return focused }
        return sessions.first
    }

    /// The name and color the user gave this tab, if any.
    var style = TabStyle()

    var title: String { style.title ?? focusedSession?.title ?? "Terminal" }
    var runningProgram: String? { sessions.lazy.compactMap(\.runningProgram).first }
    var contentView: NSView { root }
    var paneCount: Int { sessions.count }

    init(session: TerminalSession, palette: ChromePalette) {
        dividerColor = palette.outline
        sessions = [session]
        focused = session
        root.setChild(session.view)
    }

    /// Rebuilds a saved split layout, creating one session per pane (not started yet).
    init(layout: PaneLayout, style: TabStyle?, palette: ChromePalette, makeSession: (String) -> TerminalSession) {
        dividerColor = palette.outline
        self.style = style ?? TabStyle()
        var created: [TerminalSession] = []
        func build(_ node: PaneLayout) -> NSView {
            switch node {
            case .pane(let directory):
                let session = makeSession(directory)
                created.append(session)
                return session.view
            case .split(let vertical, let children):
                let split = PaneSplitView(vertical: vertical, color: palette.outline)
                children.map(build).forEach(split.addArrangedSubview)
                return split
            }
        }
        root.setChild(build(layout))
        sessions = created
        focused = created.first
        updateDimming()
        for split in allSplits(in: root.child) { split.distributeEvenly() }
    }

    /// The current panes and their folders, for restoring after a relaunch.
    var layout: PaneLayout {
        func walk(_ view: NSView) -> PaneLayout? {
            if let session = sessions.first(where: { $0.view === view }) {
                return .pane(directory: session.currentDirectory)
            }
            guard let split = view as? PaneSplitView else { return nil }
            let children = split.arrangedSubviews.compactMap(walk)
            return children.count == 1 ? children[0] : .split(vertical: split.isVertical, children: children)
        }
        return root.child.flatMap(walk) ?? .pane(directory: focusedSession?.currentDirectory ?? NSHomeDirectory())
    }

    /// What reopens this tab: its panes, name and color.
    var saved: SavedSession.Tab {
        .terminal(layout, style: style.isEmpty ? nil : style)
    }

    /// What each pane is running, in the same order as the panes of `layout`.
    var paneCommands: [String?] { sessionsInLayoutOrder().map(\.layoutCommand) }

    func contains(_ session: TerminalSession) -> Bool {
        sessions.contains { $0 === session }
    }

    func focus() {
        focusedSession?.focus()
    }

    func apply(_ snapshot: ConfigSnapshot) {
        dividerColor = ChromePalette(theme: snapshot.theme).outline
        sessions.forEach { $0.apply(snapshot) }
        for split in allSplits(in: root.child) {
            split.color = dividerColor
            split.needsDisplay = true
        }
    }

    func closeContent() {
        sessions.forEach { $0.closeContent() }
        sessions.removeAll()
    }

    // MARK: Focus

    /// Called when keyboard focus moves; returns true if it landed in a different pane.
    @discardableResult
    func noteFocus(_ responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView,
              let session = sessions.first(where: { view.isDescendant(of: $0.view) }),
              session !== focused
        else { return false }
        focused = session
        updateDimming()
        return true
    }

    func focus(_ session: TerminalSession) {
        focused = session
        updateDimming()
        session.focus()
    }

    /// Next / previous pane in layout order, wrapping around.
    func cyclePane(forward: Bool) {
        let ordered = sessionsInLayoutOrder()
        guard ordered.count > 1, let current = focusedSession,
              let index = ordered.firstIndex(where: { $0 === current }) else { return }
        let next = ordered[(index + (forward ? 1 : -1) + ordered.count) % ordered.count]
        focus(next)
    }

    /// The nearest pane in `direction` from the focused one (by on-screen position).
    func movePane(_ direction: Direction) {
        guard let current = focusedSession else { return }
        let from = frameInRoot(current.view)
        let candidates = sessions.filter { $0 !== current }.compactMap { session -> (TerminalSession, CGFloat)? in
            let frame = frameInRoot(session.view)
            let isThatWay: Bool
            switch direction {
            case .left: isThatWay = frame.maxX <= from.minX + 1
            case .right: isThatWay = frame.minX >= from.maxX - 1
            case .up: isThatWay = frame.maxY <= from.minY + 1
            case .down: isThatWay = frame.minY >= from.maxY - 1
            }
            guard isThatWay else { return nil }
            return (session, hypot(frame.midX - from.midX, frame.midY - from.midY))
        }
        if let nearest = candidates.min(by: { $0.1 < $1.1 })?.0 {
            focus(nearest)
        }
    }

    // MARK: Splitting

    /// Places `newSession` next to the focused pane: to its right (`vertical`) or below it.
    func split(adding newSession: TerminalSession, vertical: Bool) {
        guard let current = focusedSession else { return }
        let old = current.view
        let new = newSession.view
        sessions.append(newSession)

        if let parent = old.superview as? PaneSplitView, parent.isVertical == vertical,
           let index = parent.arrangedSubviews.firstIndex(of: old) {
            parent.insertArrangedSubview(new, at: index + 1)
            parent.distributeEvenly()
        } else {
            let split = PaneSplitView(vertical: vertical, color: dividerColor)
            replace(old, with: split)
            split.addArrangedSubview(old)
            split.addArrangedSubview(new)
            split.distributeEvenly()
        }
        focused = newSession
        updateDimming()
    }

    /// Removes a pane. Returns false when it was the last one (the caller closes the tab).
    func remove(_ session: TerminalSession) -> Bool {
        guard sessions.count > 1, let index = sessions.firstIndex(where: { $0 === session }) else { return false }
        let view = session.view
        let order = sessionsInLayoutOrder()
        let position = order.firstIndex(where: { $0 === session }) ?? 0
        sessions.remove(at: index)
        session.closeContent()

        if let split = view.superview as? PaneSplitView {
            view.removeFromSuperview()
            if split.arrangedSubviews.count == 1, let only = split.arrangedSubviews.first {
                only.removeFromSuperview()
                replace(split, with: only)
            } else {
                split.distributeEvenly()
            }
        }
        // Focus the pane that took its place in the layout order.
        let remaining = order.filter { $0 !== session }
        let next = remaining[min(position, remaining.count - 1)]
        focused = next
        updateDimming()
        next.focus()
        return true
    }

    // MARK: Helpers

    private func replace(_ old: NSView, with new: NSView) {
        if let split = old.superview as? PaneSplitView, let index = split.arrangedSubviews.firstIndex(of: old) {
            old.removeFromSuperview()
            split.insertArrangedSubview(new, at: index)
            split.distributeEvenly()
        } else {
            root.setChild(new)
        }
    }

    private func sessionsInLayoutOrder() -> [TerminalSession] {
        var order: [TerminalSession] = []
        func walk(_ view: NSView) {
            if let session = sessions.first(where: { $0.view === view }) {
                order.append(session)
            } else if let split = view as? PaneSplitView {
                split.arrangedSubviews.forEach(walk)
            }
        }
        if let child = root.child { walk(child) }
        return order
    }

    private func allSplits(in view: NSView?) -> [PaneSplitView] {
        guard let split = view as? PaneSplitView else { return [] }
        return [split] + split.arrangedSubviews.flatMap { allSplits(in: $0) }
    }

    private func frameInRoot(_ view: NSView) -> NSRect {
        root.convert(view.bounds, from: view)
    }

    /// With several panes, the ones without focus are dimmed slightly.
    private func updateDimming() {
        let dim = sessions.count > 1
        for session in sessions {
            session.view.alphaValue = dim && session !== focused ? 0.6 : 1
        }
    }
}

/// Holds the tab's single top-level view (a session or a split) edge to edge.
final class PaneRootView: NSView {
    private(set) var child: NSView?

    func setChild(_ view: NSView) {
        if child?.superview === self { child?.removeFromSuperview() }
        child = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// A split with a thin divider in the theme's outline color.
final class PaneSplitView: NSSplitView {
    var color: NSColor

    init(vertical: Bool, color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        isVertical = vertical
        dividerStyle = .thin
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var dividerColor: NSColor { color }

    /// Set until the split has had a size to divide evenly.
    private var wantsEvenDistribution = false

    override func layout() {
        super.layout()
        if wantsEvenDistribution { distributeEvenly() }
    }

    /// Gives every pane the same share of the space (as soon as the split has a size).
    func distributeEvenly() {
        let count = arrangedSubviews.count
        guard count > 1 else { return }
        let total = (isVertical ? bounds.width : bounds.height) - dividerThickness * CGFloat(count - 1)
        guard total > 0 else {
            wantsEvenDistribution = true
            return
        }
        wantsEvenDistribution = false
        let share = total / CGFloat(count)
        for index in 0..<(count - 1) {
            setPosition(share * CGFloat(index + 1) + dividerThickness * CGFloat(index), ofDividerAt: index)
        }
    }
}
