#if DEBUG
import AppKit
import SwiftUI
import RuneKit

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
    /// The script runs once per launch, in the first window (not again in windows it opens).
    private static var started = false

    static func runIfRequested(session: TerminalSession) {
        guard !started, let script = ProcessInfo.processInfo.environment["RUNE_DEBUG_SCRIPT"], !script.isEmpty else { return }
        started = true
        let steps = script.components(separatedBy: "||")
        run(steps[...], session: session, delay: Double(ProcessInfo.processInfo.environment["RUNE_DEBUG_STEP"] ?? "") ?? 3)
    }

    /// Drives every Settings control's write path and checks the result took effect.
    private static func runSettingsSelfTest(session: TerminalSession) {
        guard let store = ConfigStore.current else { return }
        let model = SettingsModel(store: store)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("SETTINGS \(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func set(_ key: String, _ value: Any?, _ verify: (RuneConfig) -> Bool) {
            model.set(key, value)
            check(key, verify(store.snapshot.config))
        }
        set("fontSize", 15) { $0.fontSize == 15 }
        set("fontFamily", "Menlo") { $0.fontFamily == "Menlo" }
        set("lineHeight", 1.4) { abs($0.lineHeight - 1.4) < 0.001 }
        set("theme", "rune-dark") { $0.theme == "rune-dark" }
        set("cursorStyle", "block") { $0.cursorStyle == .block }
        set("cursorBlink", true) { $0.cursorBlink }
        set("paddingX", 24) { $0.paddingX == 24 }
        set("paddingY", 8) { $0.paddingY == 8 }
        set("shell", "/bin/zsh") { $0.shell == "/bin/zsh" }
        set("shell", nil) { $0.shell == nil }
        set("honorPrompt", true) { $0.honorPrompt }
        set("honorPrompt", false) { !$0.honorPrompt }
        set("scrollback", 20000) { $0.scrollback == 20000 }
        set("optionAsMeta", false) { !$0.optionAsMeta }
        set("showWelcome", false) { !$0.showWelcome }
        set("inputMode", "shell") { $0.inputMode == .shell }
        set("inputMode", "editor") { $0.inputMode == .editor }
        set("aiIncludeBlockContext", false) { !$0.aiIncludeBlockContext }
        set("ollamaEndpoint", "http://localhost:11434") { $0.ollamaEndpoint == "http://localhost:11434" }
        set("ollamaEndpoint", nil) { $0.ollamaEndpoint == nil }
        set("aiModel", "gemma4:e2b") { $0.aiModel == "gemma4:e2b" }
        set("aiEnabled", false) { !$0.aiEnabled }
        set("aiEnabled", true) { $0.aiEnabled }
        // Per-machine override and clearing it.
        model.thisMachineOnly = true
        set("fontSize", 17) { $0.fontSize == 17 }
        check("override badge", model.isOverridden("fontSize"))
        model.thisMachineOnly = false
        model.clearOverride("fontSize")
        check("override cleared", store.snapshot.config.fontSize == 15 && !model.isOverridden("fontSize"))
        check("no write errors", store.lastWriteError == nil)
        check("no config warnings", store.snapshot.warnings.isEmpty)
        // The window applies config on the next run-loop turn; check the live terminal after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            check("font applied", session.terminalView.font.familyName == "Menlo" && abs(session.terminalView.font.pointSize - 15) < 0.01)
            check("lineHeight applied", abs(session.terminalView.lineSpacing - 1.4) < 0.001)
            check("paddingX applied", abs(session.view.terminalContainer.padding.left - 24) < 0.01)
            check("optionAsMeta applied", session.terminalView.optionAsMetaKey == false)
            check("cursor applied", store.snapshot.config.cursorStyle == .block)
            print("SETTINGS DONE failures=\(failures)")
            fflush(stdout)
        }
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
                let codes: [String: (UInt16, String)] = ["right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "end": (119, "\u{F72B}"), "tab": (48, "\t")]
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
            case let click where click.hasPrefix("@clickTreeRow:"):
                // Sends a real mouse click to the file tree row with this index.
                guard let window = session.view.window, let index = Int(click.dropFirst(14)),
                      let host = window.contentView?.subviews.first(where: { String(describing: type(of: $0)).contains("FileTreeView") }) else { break }
                let yInHost = 56 + 34 + CGFloat(index) * 26 + 13 // header + filter + rows
                let point = host.convert(NSPoint(x: 80, y: host.isFlipped ? yInHost : host.bounds.height - yInHost), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                }
            case "@splitRight", "@splitDown", "@panes", "@closePane", "@nextPane", "@palette", "@paletteRun":
                guard let controller = session.view.window?.windowController as? MainWindowController else { break }
                switch step {
                case "@splitRight": controller.splitPane(vertical: true)
                case "@splitDown": controller.splitPane(vertical: false)
                case "@closePane": controller.closeTab(nil)
                case "@nextPane": controller.selectNextPane(nil)
                case "@palette": controller.showCommandPalette(nil)
                case "@paletteRun": controller.debugPalette?.runSelected()
                default: controller.debugPanes()
                }
            case let query where query.hasPrefix("@paletteQuery:"):
                guard let controller = session.view.window?.windowController as? MainWindowController,
                      let palette = controller.debugPalette else { print("PALETTE closed"); break }
                palette.query = String(query.dropFirst(14))
                print("PALETTE \"\(palette.query)\" → " + palette.results.prefix(5).map { "\($0.kind.rawValue):\($0.title)" }.joined(separator: " | "))
                fflush(stdout)
            case "@editor":
                if let controller = session.view.window?.windowController as? MainWindowController, let focused = controller.selectedSession {
                    let editor = focused.view.inputArea.editor
                    print("EDITOR text=<\(editor.string)> sel=\(editor.selectedRange()) workflow=\(editor.fillingWorkflow)")
                    fflush(stdout)
                }
            case let tab where tab.hasPrefix("@tab:"):
                if let controller = session.view.window?.windowController as? MainWindowController, let index = Int(tab.dropFirst(5)),
                   controller.tabSummaries.indices.contains(index) {
                    controller.selectTab(withID: controller.tabSummaries[index].id)
                }
            case "@find":
                if let controller = session.view.window?.windowController as? MainWindowController {
                    let item = NSMenuItem()
                    item.tag = NSTextFinder.Action.showFindInterface.rawValue
                    controller.findInTab(item)
                }
            case let run where run.hasPrefix("@runSnippet:"):
                if let controller = session.view.window?.windowController as? MainWindowController, let index = Int(run.dropFirst(12)) {
                    controller.debugSelectedPreview()?.debugRunSnippet(index)
                }
            case "@recall":
                (session.view.window?.windowController as? MainWindowController)?.showRecall(nil)
            case let query where query.hasPrefix("@recallQuery:"):
                if let recall = (session.view.window?.windowController as? MainWindowController)?.debugRecall {
                    recall.query = String(query.dropFirst(13))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        print("RECALL \"\(recall.query)\" → " + recall.results.prefix(4).map { "\($0.command) [\($0.output.prefix(30).replacingOccurrences(of: "\n", with: "⏎"))]" }.joined(separator: " | "))
                        fflush(stdout)
                    }
                }
            case "@recallInsert":
                (session.view.window?.windowController as? MainWindowController)?.debugRecall?.insertSelected()
            case "@fonts":
                for name in ["Caveat", "Instrument Serif", "JetBrains Mono"] {
                    print("FONT \(name): \(NSFontManager.shared.availableMembers(ofFontFamily: name)?.count ?? 0) faces")
                }
                print("FONT terminal uses \(session.terminalView.font.familyName ?? "?")")
                fflush(stdout)
            case "@hotkey":
                for spec in ["ctrl+`", "option+space", "cmd+shift+t", "t", "ctrl+nope", "off"] {
                    let ok = GlobalHotKey.shared.register(spec)
                    print("HOTKEY \(spec) → registered=\(ok) current=\(GlobalHotKey.shared.current ?? "none") display=\(GlobalHotKey.display(spec))")
                }
                GlobalHotKey.shared.unregister()
                fflush(stdout)
            case let link where link.hasPrefix("@link:"):
                session.terminalView.requestOpenLink(source: session.terminalView, link: String(link.dropFirst(6)), params: [:])
            case let query where query.hasPrefix("@filter:"):
                if let block = session.tracker.blocks.last {
                    session.view.showFilter(command: session.commandText(of: block), output: session.outputText(of: block))
                    if let host = session.view.subviews.compactMap({ $0 as? NSHostingView<BlockFilterView> }).first {
                        host.rootView.model.query = String(query.dropFirst(8))
                        print("FILTER \(host.rootView.model.matches.count)/\(host.rootView.model.totalLines) → " + host.rootView.model.matches.prefix(5).map { "\($0.id):\($0.text)" }.joined(separator: " | "))
                        fflush(stdout)
                    }
                }
            case let text where text.hasPrefix("@send:"):
                session.terminalView.sendToShell(Array((String(text.dropFirst(6)) + "\r").utf8))
            case "@remoteAccept":
                session.acceptRemoteOffer(always: false)
            case "@remote":
                let blocks = session.tracker.blocks.suffix(3).map { "[\($0.command) exit=\($0.exitCode.map(String.init) ?? "-") cwd=\($0.cwd)]" }.joined(separator: " ")
                print("REMOTE state=\(session.remote) mode=\(session.mode) editorText=<\(session.view.inputArea.editor.string)> blocks=\(blocks)")
                fflush(stdout)
            case let style where style.hasPrefix("@tabStyle:"):
                (session.view.window?.windowController as? MainWindowController)?.debugStyleSelectedTab(String(style.dropFirst(10)))
            case "@renameTab":
                (session.view.window?.windowController as? MainWindowController)?.renameTab(nil)
            case let service where service.hasPrefix("@service:"):
                // `@service:tab:/path` or `@service:window:/path`, as Finder would send it.
                let parts = service.dropFirst(9).split(separator: ":", maxSplits: 1).map(String.init)
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("RuneDebugService"))
                pasteboard.clearContents()
                pasteboard.writeObjects([URL(fileURLWithPath: parts.last ?? "/") as NSURL])
                var message: NSString?
                if let delegate = NSApp.delegate as? AppDelegate {
                    if parts.first == "window" { delegate.newWindowHere(pasteboard, userData: nil, error: &message) } else { delegate.newTabHere(pasteboard, userData: nil, error: &message) }
                }
            case let name where name.hasPrefix("@saveLayout:"):
                if let controller = session.view.window?.windowController as? MainWindowController,
                   let store = (NSApp.delegate as? AppDelegate)?.layoutStore {
                    try? store.save(controller.currentLayout(named: String(name.dropFirst(12))))
                    print("LAYOUT saved " + store.directory.path)
                }
            case let name where name.hasPrefix("@openLayout:"):
                let wanted = String(name.dropFirst(12))
                if let delegate = NSApp.delegate as? AppDelegate, let entry = delegate.layoutStore?.loadAll().first(where: { $0.layout.name == wanted }) {
                    delegate.openLayout(entry.layout)
                }
            case "@allTabs":
                for controller in NSApp.windows.compactMap({ $0.windowController as? MainWindowController }) {
                    controller.debugDumpTabs()
                }
            case "@newTab":
                (session.view.window?.windowController as? MainWindowController)?.newTab(nil)
            case "@closeTab":
                (session.view.window?.windowController as? MainWindowController)?.closeTab(nil)
            case "@reopen":
                (session.view.window?.windowController as? MainWindowController)?.reopenClosedTab(nil)
            case "@gap":
                // Distance between the last non-blank row on screen and the terminal area's bottom.
                let terminal = session.terminalView.getTerminal()
                let container = session.view.terminalContainer
                let geometry = session.geometry
                let screenTop = geometry.linesTrimmed + geometry.screenTop
                let lastText = (0..<terminal.rows).last {
                    !(terminal.getScrollInvariantLine(row: screenTop + $0)?.translateToString(trimRight: true).isEmpty ?? true)
                } ?? -1
                let bottom = session.terminalView.frame.minY + CGFloat(lastText + 1) * geometry.cellHeight
                print("GAP hidden=\(container.hiddenBottomRows) rows=\(terminal.rows) lastText=\(lastText) cell=\(geometry.cellHeight) gap=\(container.bounds.height - bottom) mode=\(session.mode)")
                fflush(stdout)
            case let snap where snap.hasPrefix("@snapshot:"):
                // Renders the window's content offscreen (works even when the window is covered).
                guard let view = session.view.window?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: String(snap.dropFirst(10))))
                }
            case let shot where shot.hasPrefix("@webshot:"):
                if let controller = session.view.window?.windowController as? MainWindowController {
                    controller.debugSelectedPreview()?.debugWebSnapshot(to: String(shot.dropFirst(9)))
                }
            case let size where size.hasPrefix("@height:"):
                if let window = session.view.window, let h = Double(size.dropFirst(8)) {
                    var frame = window.frame
                    frame.origin.y -= CGFloat(h) - frame.height
                    frame.size.height = CGFloat(h)
                    window.setFrame(frame, display: true)
                }
            case "@onboarding":
                NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: nil)
            case let shot where shot.hasPrefix("@onboardingShot:"):
                // Renders the onboarding window offscreen, then advances to the next step.
                if let window = NSApp.windows.first(where: { $0.windowController is OnboardingWindowController }),
                   let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(shot.dropFirst(16))))
                    (window.contentView as? NSHostingView<OnboardingView>)?.rootView.model.next()
                }
            case let scroll where scroll.hasPrefix("@scrollPreview:"):
                if let controller = session.view.window?.windowController as? MainWindowController, let points = Double(scroll.dropFirst(15)) {
                    controller.debugSelectedPreview()?.debugScroll(by: CGFloat(points))
                }
            case "@settingsTest":
                runSettingsSelfTest(session: session)
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
                for b in session.tracker.blocks { print("DUMP block \(b.command) took=\(String(format: "%.2f", b.duration()))s header=\(b.headerRow) out=\(b.outputStartRow) end=\(b.endRow ?? -1) screenTop=\(g.linesTrimmed + g.screenTop)") }
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
