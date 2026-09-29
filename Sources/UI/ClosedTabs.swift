import Foundation
import RuneKit

/// Recently closed tabs and panes (this run only), for ⇧⌘T.
final class ClosedTabs {
    static let shared = ClosedTabs()
    private var stack: [SavedSession.Tab] = []
    private static let limit = 20

    var isEmpty: Bool { stack.isEmpty }

    func push(_ tab: SavedSession.Tab) {
        stack.append(tab)
        if stack.count > Self.limit { stack.removeFirst(stack.count - Self.limit) }
    }

    func pop() -> SavedSession.Tab? {
        stack.popLast()
    }
}
