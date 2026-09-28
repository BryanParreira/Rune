#if DEBUG
import AppKit

/// Debug builds only: runs a scripted sequence against the first session so the UI can be
/// exercised without synthetic key events. Set RUNE_DEBUG_SCRIPT to steps separated by "||":
///   plain text      → typed into the editor and submitted
///   @prev / @next   → Cmd-Up / Cmd-Down block selection
///   @clear          → Cmd-K
///   @wait           → extra pause
///   @settings       → open the Settings window
///   @type:text      → type into the editor without submitting
///   @ai:question    → ask the AI
///   @dump           → print AI conversation state to stdout
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
            case "@tree":
                NSApp.sendAction(#selector(MainWindowController.toggleFileTree(_:)), to: nil, from: nil)
            case "@dump":
                let c = session.view.conversation
                let t = session.terminalView.getTerminal()
                let g = session.geometry
                print("DUMP layout terminalHeight=\(session.terminalView.frame.height) sessionHeight=\(session.view.frame.height) aiVisible=\(c.isVisible) collapsed=\(c.isCollapsed)")
                print("DUMP screen cursorY=\(t.getCursorLocation().y) rows=\(t.rows) lines=\(g.lineCount) top=\(g.topVisibleRow) mode=\(session.mode)")
                for b in session.tracker.blocks { print("DUMP block \(b.command) header=\(b.headerRow) out=\(b.outputStartRow) end=\(b.endRow ?? -1) screenTop=\(g.linesTrimmed + g.screenTop)") }
                print("DUMP running=\(session.runningProgram ?? "nil")")
                print("DUMP state=\(c.state) model=\(c.model) context=\(c.contextLabel ?? "-")")
                print("DUMP earlier=\(c.earlier.map(\.prompt)) prompt=\(c.prompt)")
                print("DUMP reply<<\(c.reply)>>")
                for seg in c.segments {
                    switch seg {
                    case .text(let t): print("DUMP seg text(\(t.count) chars)")
                    case .command(let cmd, let done): print("DUMP seg COMMAND[\(done)] \(cmd)")
                    case .code(let lang, let code, _): print("DUMP seg code[\(lang)] \(code.count) chars")
                    }
                }
                print("DUMP service ready=\(AIService.shared.isReady) active=\(AIService.shared.activeModel ?? "nil") status=\(AIService.shared.status)")
                fflush(stdout)
            case let question where question.hasPrefix("@ai:"):
                session.askAI(String(question.dropFirst(4)))
            case let typed where typed.hasPrefix("@type:"):
                let editor = session.view.inputArea.editor
                editor.insertText(String(typed.dropFirst(6)), replacementRange: editor.selectedRange())
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
