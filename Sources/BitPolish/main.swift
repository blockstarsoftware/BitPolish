import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var session: SessionController!
    private var statusItem: StatusItemController!
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        session = SessionController()
        statusItem = StatusItemController(session: session) { NSApp.terminate(nil) }
        Dock.installMainMenu(about: #selector(showAbout), settings: #selector(showSettings), checkForUpdates: #selector(checkForUpdates),
                             welcome: #selector(showWelcome), target: self)
        Updates.shared.start()   // daily update check while running, if set up
        session.keepOnIfSet()
        // The welcome, on the very first launch only.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            WelcomeWindow.shared.showIfFirstLaunch { self?.statusItem.showPanel() }
        }
        #if BITPOLISH_TESTING
        TestHooks.install(session: session, statusItem: statusItem)
        #endif

        // Restore on SIGTERM/SIGINT too (e.g. `kill`, or Ctrl-C when run from Terminal).
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.session.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Show in Dock

    /// A click on the Dock icon opens the panel under the menu-bar readout.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem.showPanel()
        return false
    }

    /// The Dock icon's menu: the switch, as a click would flip it.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Bit-Perfect Listening", action: #selector(toggleListening), keyEquivalent: "")
        item.target = self
        item.state = session.isOn ? .on : .off
        menu.addItem(item)
        let readout = NSMenuItem(title: "Show in Menu Bar", action: #selector(toggleReadout), keyEquivalent: "")
        readout.target = self
        readout.state = statusItem.readoutShown ? .on : .off
        menu.addItem(readout)
        return menu
    }

    @objc private func toggleListening() { statusItem.flipFromMenu(!session.isOn) }

    @objc private func toggleReadout() { statusItem.setReadoutShown(!statusItem.readoutShown) }

    @objc private func showSettings() { statusItem.showSettings() }

    @objc private func showWelcome() { statusItem.showWelcome() }

    @objc private func showAbout() { AboutWindow.shared.show() }

    @objc private func checkForUpdates() { Updates.shared.checkForUpdates() }

    /// The Dock menu item is disabled whenever the panel's switch would be.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleListening) else { return true }
        return !session.movingOutput && (session.isOn || session.canActivate)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session.shutdown()
        return .terminateNow
    }
}

/// Only one BitPolish may run: a second copy's startup would restore the device
/// the first one is managing. An exclusive lock on a file in Application
/// Support decides; the system releases it if BitPolish exits or crashes.
private func acquireSingleInstanceLock() -> Bool {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BitPolish", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }   // can't lock: don't refuse to run
    return flock(fd, LOCK_EX | LOCK_NB) == 0   // fd stays open for the process's lifetime
}

guard acquireSingleInstanceLock() else {
    NSLog("BitPolish is already running.")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Dock.isShown ? .regular : .accessory)   // menu-bar app unless Show in Dock is checked
    app.run()
}
