import AppKit

/// Show in Dock: an opt-in Dock icon (and a place in ⌘-Tab) while BitPolish
/// runs. The app still works only from the menu bar; the Dock icon opens the
/// panel, and its menu flips the switch.
@MainActor
enum Dock {
    private static let key = "ShowInDock"

    static var isShown: Bool { UserDefaults.standard.bool(forKey: key) }

    /// True while the menu-bar readout is out of the menu bar: the Dock icon
    /// is then the way in, whatever Show in Dock says.
    static var readoutHidden = false

    /// Saves the choice and applies it at once.
    static func setShown(_ shown: Bool) {
        UserDefaults.standard.set(shown, forKey: key)
        apply()
    }

    /// Sets the activation policy from the saved choice and the readout (at
    /// launch, and on change).
    static func apply() {
        let policy: NSApplication.ActivationPolicy = isShown || readoutHidden ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// The menu bar's app menu, shown while BitPolish is a frontmost Dock app.
    /// Installed in both modes: in menu-bar mode it supplies Copy and the
    /// standard shortcuts to BitPolish's own windows.
    /// Ordered as Apple's Human Interface Guidelines lay out the app menu.
    static func installMainMenu(about: Selector, settings: Selector, checkForUpdates: Selector, welcome: Selector,
                                target: AnyObject) {
        let main = NSMenu()

        let appMenu = NSMenu(title: "BitPolish")
        appMenu.addItem(item("About BitPolish", about, target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", settings, key: ",", target: target))
        appMenu.addItem(item("Check for Updates…", checkForUpdates, target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide BitPolish", #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit BitPolish", #selector(NSApplication.terminate(_:)), key: "q"))
        main.addItem(submenu(appMenu))

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), key: "w"))
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("Welcome to BitPolish", welcome, target: target))
        main.addItem(submenu(help))
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private static func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
