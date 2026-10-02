import AppKit
import RuneKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(shellMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Rune")
        menu.addItem(item("About Rune", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        if UpdateController.shared.isAvailable {
            let update = item("Check for Updates…", #selector(UpdateController.checkForUpdates(_:)))
            update.target = UpdateController.shared
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(item("Welcome Guide…", #selector(AppDelegate.showOnboarding(_:))))
        menu.addItem(item("Settings…", #selector(AppDelegate.openSettings(_:)), ","))
        menu.addItem(item("Open config.json", #selector(AppDelegate.openConfig(_:))))
        menu.addItem(item("Reveal Config Folder", #selector(AppDelegate.revealConfigFolder(_:))))
        menu.addItem(item("Reload Config", #selector(AppDelegate.reloadConfig(_:)), "r", [.command, .shift]))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide Rune", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Rune", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func shellMenu() -> NSMenu {
        let menu = NSMenu(title: "Shell")
        menu.addItem(item("New Tab", #selector(MainWindowController.newTab(_:)), "t"))
        menu.addItem(item("New Window", #selector(AppDelegate.newWindow(_:)), "n"))
        menu.addItem(item("Reopen Closed Tab", #selector(MainWindowController.reopenClosedTab(_:)), "t", [.command, .shift]))
        menu.addItem(item("Rename Tab…", #selector(MainWindowController.renameTab(_:)), ""))
        menu.addItem(item("Move Tab to New Window", #selector(MainWindowController.moveTabToNewWindow(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Save Window as Layout…", #selector(MainWindowController.saveLayout(_:)), ""))
        let layouts = NSMenu(title: "Open Layout")
        layouts.delegate = LayoutsMenu.shared
        let open = NSMenuItem(title: "Open Layout", action: nil, keyEquivalent: "")
        open.submenu = layouts
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(item("Split Pane Right", #selector(MainWindowController.splitRight(_:)), "d"))
        menu.addItem(item("Split Pane Down", #selector(MainWindowController.splitDown(_:)), "d", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Copy Last Output", #selector(MainWindowController.copyLatestOutput(_:)), "c", [.command, .shift]))
        menu.addItem(item("Copy Last Block as Image", #selector(MainWindowController.copyLatestBlockImage(_:)), "c", [.command, .option]))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        // Routed by the window to the terminal output (or the file viewer), whichever the
        // selected tab shows: the input editor would otherwise swallow them.
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
        ] {
            let entry = item(title, #selector(MainWindowController.findInTab(_:)), key, modifiers)
            entry.tag = action.rawValue
            menu.addItem(entry)
        }
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Command Palette…", #selector(MainWindowController.showCommandPalette(_:)), "p"))
        menu.addItem(item("Toggle File Tree", #selector(MainWindowController.toggleFileTree(_:)), "b"))
        menu.addItem(item("Search History (Recall)…", #selector(MainWindowController.showRecall(_:)), "h", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Select Previous Block", #selector(MainWindowController.selectPreviousBlock(_:)), "\u{F700}"))
        menu.addItem(item("Select Next Block", #selector(MainWindowController.selectNextBlock(_:)), "\u{F701}"))
        menu.addItem(item("Extend Selection Up", #selector(MainWindowController.extendSelectionUp(_:)), "\u{F700}", [.command, .shift]))
        menu.addItem(item("Extend Selection Down", #selector(MainWindowController.extendSelectionDown(_:)), "\u{F701}", [.command, .shift]))
        menu.addItem(item("Compare with Previous Run", #selector(MainWindowController.compareRuns(_:)), "d", [.command, .option]))
        menu.addItem(item("Quick Look Path Under Pointer", #selector(MainWindowController.quickLookPath(_:)), "y"))
        menu.addItem(.separator())
        menu.addItem(item("Jump to Previous Error", #selector(MainWindowController.previousError(_:)), "'"))
        menu.addItem(item("Jump to Next Error", #selector(MainWindowController.nextError(_:)), "'", [.command, .shift]))
        menu.addItem(item("Bookmark Block", #selector(MainWindowController.toggleBookmark(_:)), "b", [.command, .option]))
        menu.addItem(item("Previous Bookmark", #selector(MainWindowController.previousBookmark(_:)), "\u{F700}", [.command, .control]))
        menu.addItem(item("Next Bookmark", #selector(MainWindowController.nextBookmark(_:)), "\u{F701}", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Clear Screen", #selector(MainWindowController.clearScreen(_:)), "k"))
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Report a Problem…", #selector(AppDelegate.reportProblem(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Next Tab", #selector(MainWindowController.selectNextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item("Show Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)), "[", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Next Pane", #selector(MainWindowController.selectNextPane(_:)), "]"))
        menu.addItem(item("Previous Pane", #selector(MainWindowController.selectPreviousPane(_:)), "["))
        menu.addItem(item("Pane on the Left", #selector(MainWindowController.selectPaneLeft(_:)), "\u{F702}", [.command, .option]))
        menu.addItem(item("Pane on the Right", #selector(MainWindowController.selectPaneRight(_:)), "\u{F703}", [.command, .option]))
        menu.addItem(item("Pane Above", #selector(MainWindowController.selectPaneAbove(_:)), "\u{F700}", [.command, .option]))
        menu.addItem(item("Pane Below", #selector(MainWindowController.selectPaneBelow(_:)), "\u{F701}", [.command, .option]))
        for number in 1...9 {
            let title = number == 9 ? "Select Last Tab" : "Select Tab \(number)"
            let entry = item(title, #selector(MainWindowController.selectTabByNumber(_:)), "\(number)")
            entry.tag = number
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

/// Shell > Open Layout: the saved layouts, read when the menu opens.
final class LayoutsMenu: NSObject, NSMenuDelegate {
    static let shared = LayoutsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = (NSApp.delegate as? AppDelegate)?.layoutStore?.loadAll() ?? []
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No Saved Layouts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.layout.name, action: #selector(AppDelegate.openLayoutFromMenu(_:)), keyEquivalent: "")
            item.representedObject = entry.file
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Layouts Folder", action: #selector(AppDelegate.showLayoutsFolder(_:)), keyEquivalent: ""))
    }
}

// MARK: - Custom shortcuts

extension MainMenu {
    /// Shortcuts as the menus were built, by command title, to go back to.
    private static var defaults: [String: (key: String, modifiers: NSEvent.ModifierFlags)] = [:]

    /// Commands whose shortcut can be changed: every menu item that performs an action, by
    /// title, with its menu ("Shell › Split Pane Right").
    static func customizableItems() -> [(menu: String, item: NSMenuItem)] {
        guard let main = NSApp.mainMenu else { return [] }
        var items: [(String, NSMenuItem)] = []
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items where item.action != nil && !item.isSeparatorItem && item.submenu == nil && !item.title.isEmpty {
                // Remember the built-in shortcut before anything overrides it.
                if defaults[item.title] == nil { defaults[item.title] = (item.keyEquivalent, item.keyEquivalentModifierMask) }
                items.append((top.title.isEmpty ? "Rune" : top.title, item))
            }
        }
        return items
    }

    /// Applies `keyboardShortcuts` from config.json over the built-in shortcuts.
    static func applyShortcuts(_ overrides: [String: String]) {
        for (_, item) in customizableItems() {
            guard let original = defaults[item.title] else { continue }
            guard let text = overrides[item.title] else {
                item.keyEquivalent = original.key
                item.keyEquivalentModifierMask = original.modifiers
                continue
            }
            guard let spec = ShortcutSpec(text) else {
                // "none" (or something unreadable, reported as a config warning): no shortcut.
                item.keyEquivalent = ""
                continue
            }
            item.keyEquivalent = keyEquivalent(for: spec.key)
            var modifiers: NSEvent.ModifierFlags = []
            if spec.command { modifiers.insert(.command) }
            if spec.shift { modifiers.insert(.shift) }
            if spec.option { modifiers.insert(.option) }
            if spec.control { modifiers.insert(.control) }
            item.keyEquivalentModifierMask = modifiers
        }
    }

    /// The built-in shortcut of a command, for display after a reset.
    static func defaultShortcut(of title: String) -> String? {
        guard let original = defaults[title], !original.key.isEmpty else { return nil }
        return display(key: original.key, modifiers: original.modifiers)
    }

    private static func keyEquivalent(for key: String) -> String {
        switch key {
        case "up": return "\u{F700}"
        case "down": return "\u{F701}"
        case "left": return "\u{F702}"
        case "right": return "\u{F703}"
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case "escape": return "\u{1b}"
        default:
            if key.hasPrefix("f"), let n = Int(key.dropFirst()), (1...20).contains(n), let scalar = UnicodeScalar(0xF704 + n - 1) {
                return String(Character(scalar))
            }
            return key
        }
    }

    /// ⌃⌥⇧⌘ + key, as menus show it.
    static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        let names: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "\r": "↵", "\t": "⇥", " ": "Space", "\u{8}": "⌫", "\u{1b}": "esc"]
        var symbol = names[key] ?? key.uppercased()
        if let scalar = key.unicodeScalars.first, (0xF704...0xF717).contains(scalar.value) { symbol = "F\(scalar.value - 0xF704 + 1)" }
        var shown = ""
        if modifiers.contains(.control) { shown += "⌃" }
        if modifiers.contains(.option) { shown += "⌥" }
        if modifiers.contains(.shift) || key != key.lowercased() { shown += "⇧" }
        if modifiers.contains(.command) { shown += "⌘" }
        return shown + symbol
    }

    /// A shortcut typed in the recorder, as config text; nil if it needs a modifier.
    static func spec(from event: NSEvent) -> ShortcutSpec? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let names: [UInt16: String] = [126: "up", 125: "down", 123: "left", 124: "right", 36: "return", 48: "tab", 49: "space", 51: "delete", 53: "escape"]
        let functionKeys: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12]
        let key: String
        if let name = names[event.keyCode] {
            key = name
        } else if let number = functionKeys[event.keyCode] {
            key = "f\(number)"
        } else if let character = event.charactersIgnoringModifiers?.lowercased(), character.count == 1 {
            key = character
        } else {
            return nil
        }
        let spec = ShortcutSpec(key: key, command: flags.contains(.command), shift: flags.contains(.shift),
                                option: flags.contains(.option), control: flags.contains(.control))
        return ShortcutSpec(spec.text)
    }
}
