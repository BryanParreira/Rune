#if DEBUG
import AppKit

/// Debug builds only: runs a scripted sequence against the first session so the UI can be
/// exercised without synthetic key events. Set RUNE_DEBUG_SCRIPT to steps separated by "||":
///   plain text      → typed into the editor and submitted
///   @prev / @next   → Cmd-Up / Cmd-Down block selection
///   @clear          → Cmd-K
///   @wait           → extra pause
///   @settings       → open the Settings window
enum DebugDriver {
    static func runIfRequested(session: TerminalSession) {
        guard let script = ProcessInfo.processInfo.environment["RUNE_DEBUG_SCRIPT"], !script.isEmpty else { return }
        let steps = script.components(separatedBy: "||")
        run(steps[...], session: session, delay: 3)
    }

    private static func run(_ steps: ArraySlice<String>, session: TerminalSession, delay: TimeInterval) {
        guard let step = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak session] in
            guard let session else { return }
            switch step {
            case "@prev": session.selectAdjacentBlock(previous: true)
            case "@next": session.selectAdjacentBlock(previous: false)
            case "@clear": session.clearScreen()
            case "@wait": break
            case "@settings": NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
            default:
                if session.mode == .editor {
                    session.submit(step)
                } else {
                    session.terminalView.sendToShell(Array(step.utf8) + [13])
                }
            }
            run(steps.dropFirst(), session: session, delay: 1.5)
        }
    }
}
#endif
