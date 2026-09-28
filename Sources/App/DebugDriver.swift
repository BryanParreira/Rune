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
            case let open where open.hasPrefix("@open:") || open.hasPrefix("@pin:"):
                let pinned = open.hasPrefix("@pin:")
                let path = String(open.drop(while: { $0 != ":" }).dropFirst())
                (session.view.window?.windowController as? MainWindowController)?.openFile(path: path, pinned: pinned)
            case "@tabs":
                (session.view.window?.windowController as? MainWindowController)?.debugDumpTabs()
            case let key where key.hasPrefix("@key:"):
                let editor = session.view.inputArea.editor
                let codes: [String: (UInt16, String)] = ["right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "end": (119, "\u{F72B}")]
                if let (code, chars) = codes[String(key.dropFirst(5))],
                   let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                                windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    print("KEY before text=<\(editor.string)> suffix=<\(editor.suggestionSuffix ?? "nil")> sel=\(editor.selectedRange())")
                    let start = Date()
                    editor.keyDown(with: event)
                    print("KEY \(key) handled in \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000))ms text=<\(editor.string)> suffix=<\(editor.suggestionSuffix ?? "nil")> height=\(editor.frame.height) rows=\(session.terminalView.getTerminal().rows)")
                    fflush(stdout)
                }
            case "@tree":
                NSApp.sendAction(#selector(MainWindowController.toggleFileTree(_:)), to: nil, from: nil)
            case "@dump":
                let c = session.view.conversation
                let t = session.terminalView.getTerminal()
                let g = session.geometry
                let v = session.view
                v.window?.layoutIfNeeded()
                if let stack = v.subviews.first(where: { $0 is NSStackView }) as? NSStackView {
                    print("DUMP stack frame=\(stack.frame) arranged=\(stack.arrangedSubviews.map { "\(type(of: $0))(h=\(Int($0.frame.height)),y=\(Int($0.frame.minY)),hidden=\($0.isHidden))" })")
                    if let root = v.window?.contentView {
                        print("DUMP root " + root.subviews.map { "\(type(of: $0))(h=\(Int($0.frame.height)),y=\(Int($0.frame.minY)),hidden=\($0.isHidden),amb=\($0.hasAmbiguousLayout))" }.joined(separator: " "))
                        if let area = v.superview { print("DUMP contentArea h=\(Int(area.frame.height)) sessionInArea=\(v.frame)") }
                    }
                    print("DUMP stack views=\(stack.views.count) window=\(v.window?.frame.size ?? .zero) ambiguous=\(v.hasAmbiguousLayout)")
                    for c in v.constraints + stack.constraints where c.priority == .required && c.firstItem === v.terminalContainer { print("DUMP c \(c)") }
                }
                print("DUMP layout session=\(Int(v.frame.height)) container=\(Int(v.terminalContainer.frame.height)) terminal=\(Int(session.terminalView.frame.height)) input=\(Int(v.inputArea.frame.height)) inputY=\(Int(v.inputArea.frame.minY)) aiVisible=\(c.isVisible) collapsed=\(c.isCollapsed)")
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
