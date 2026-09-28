import AppKit

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
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(MainWindowController.closeTab(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = item("Find…", #selector(NSResponder.performTextFinderAction(_:)), "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(find)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Toggle File Tree", #selector(MainWindowController.toggleFileTree(_:)), "b"))
        menu.addItem(.separator())
        menu.addItem(item("Select Previous Block", #selector(MainWindowController.selectPreviousBlock(_:)), "\u{F700}"))
        menu.addItem(item("Select Next Block", #selector(MainWindowController.selectNextBlock(_:)), "\u{F701}"))
        menu.addItem(.separator())
        menu.addItem(item("Clear Screen", #selector(MainWindowController.clearScreen(_:)), "k"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Show Next Tab", #selector(MainWindowController.selectNextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item("Show Previous Tab", #selector(MainWindowController.selectPreviousTab(_:)), "[", [.command, .shift]))
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
