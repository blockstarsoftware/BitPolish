import AppKit
import Combine
import BitPolishCore
import SwiftUI

/// Owns the menu-bar item and the panel.
///
/// The panel is a system popover anchored to the menu-bar item. Since macOS
/// 26 an app can't keep its menu-bar item highlighted by itself
/// (`highlight(true)` no longer draws the capsule); the system keeps it lit
/// for its own presentations, such as menus and popovers anchored to the item.
///
/// Show/hide: clicking the item toggles the popover; clicking elsewhere or
/// pressing Escape closes it (transient behavior); a right click opens a
/// small menu with About, Check for Updates… and Quit; an Option-click adds
/// a Details section, as Apple's own menu-bar items do. A click on the item
/// while the popover is open first closes it (as an outside click) and then
/// reaches the item's action, which would reopen it. `lastAutoClose` guards
/// against that.
///
/// Switching On, in stages:
///  1. The popover grows to the card's final height (the popover animates
///     its own frame, which is the roll-down).
///  2. The details' space is reserved but hidden behind a status line naming
///     the change being made to the device.
///  3. Once both the roll-down and the device change are done, the details
///     fade in, in place.
/// Switching Off: the details fade and the popover rolls back up.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let hosting: NSHostingController<PopoverContent>
    private let sizer: NSHostingController<CardView>
    private let session: SessionController
    private let panelState: PanelState
    private let onQuit: () -> Void
    private var keyMonitor: Any?
    private var lastAutoClose = Date.distantPast
    private var populateWork: DispatchWorkItem?
    private var flipGeneration = 0
    private var cancellables = Set<AnyCancellable>()
    private var readoutObservation: NSKeyValueObservation?

    init(session: SessionController, onQuit: @escaping () -> Void) {
        self.session = session
        self.onQuit = onQuit
        let state = PanelState(populated: session.isOn)
        panelState = state
        sizer = NSHostingController(rootView: CardView(session: session, state: state, onToggle: { _ in }, onQuit: {}))
        hosting = NSHostingController(rootView: PopoverContent(session: session, state: state, onToggle: { _ in }, onQuit: onQuit))
        hosting.sizingOptions = []   // the popover's size is set here, not by SwiftUI
        super.init()

        hosting.rootView = PopoverContent(session: session, state: state,
                                          onToggle: { [weak self] in self?.flipSwitch($0) }, onQuit: onQuit,
                                          onAbout: { [weak self] in self?.close(); self?.showAbout() },
                                          onChooseOutput: { [weak self] in self?.chooseOutput($0) })
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // ⌘-drag can take the readout out of the menu bar (macOS remembers
        // the choice); the Dock icon is then the way in.
        item.behavior = .removalAllowed
        readoutObservation = item.observe(\.isVisible, options: [.initial, .new]) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.readoutVisibilityChanged(item.isVisible) }
        }
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        updateLabel()

        session.objectWillChange
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &cancellables)
        Updates.shared.objectWillChange
            .sink { [weak self] _ in self?.queueRefresh() }
            .store(in: &cancellables)
    }

    /// Set while a label and size refresh is queued, so a burst of session
    /// changes (a rate change publishes several in a row) gets one refresh.
    private var refreshQueued = false

    /// objectWillChange fires before each change lands, so the refresh runs
    /// on a later pass and reads the settled values. The flag is cleared
    /// before anything is read, so a change after that point queues another.
    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.updateLabel()
            self.fitPopover()
        }
    }

    // MARK: Menu-bar label

    /// Two small stacked lines, like the system's compact menu-bar readouts:
    ///   24-bit
    ///  44.1 kHz
    /// Always the format the device is actually running at (what reaches the
    /// DAC). Full strength while On; dimmed while Off, as a read-only readout.
    private func updateLabel() {
        guard let button = item.button else { return }
        var bits = session.deviceBits > 0 ? "\(session.deviceBits)-bit" : "–"
        // An asterisk: the rate is true, with a caveat (the panel says which).
        var rate = session.deviceRate > 0 ? "\(Format.rate(session.deviceRate)) kHz\(session.notBitPerfect ? "*" : "")" : "–"
        // Not a DAC output (built-in, Bluetooth, AirPlay, virtual): say so
        // instead of showing a format that means nothing for bit-perfect use.
        if !session.isOn, let short = session.caps?.ineligibleShort {
            bits = short
            rate = "output"
        }
        button.image = Self.stackedImage(top: bits, bottom: rate, dimmed: !session.isOn)
        #if BITPOLISH_TESTING
        TestHooks.dumpLabel(button.image)
        #endif
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("BitPolish, \(bits), \(rate.replacingOccurrences(of: "*", with: ""))\(session.isOn ? (session.notBitPerfect ? ", not bit-perfect" : "") : ", Bit-Perfect Listening off")")
    }

    /// Apple's minimum text size; two lines still fit the 24 pt menu bar.
    private static let labelFontSize: CGFloat = 10

    /// Width of the widest possible readout (semibold, the wider weight),
    /// across every standard rate, bit depth and output label. Every readout
    /// image is this wide, so the menu-bar item never resizes when its text
    /// changes and the popover never has to move.
    static let textWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .semibold)
        let samples = ["16-bit", "24-bit", "32-bit"] +
            ["44.1", "48", "88.2", "96", "176.4", "192", "352.8", "384", "705.6", "768"].map { "\($0) kHz*" } +
            ["Built-in", "Bluetooth", "AirPlay", "Virtual", "output"]
        let widest = samples.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 40
        return ceil(widest) + 2
    }()

    /// Renders the two lines as a template image, so the menu bar tints it for
    /// light and dark mode and for the highlighted state, like system items.
    /// Always the same width, centered.
    static func stackedImage(top: String, bottom: String, dimmed: Bool) -> NSImage {
        // Off reads as quieter in two ways (lighter weight and lower opacity),
        // so it stays legible without looking like the On state.
        let font = NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: dimmed ? .medium : .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let alpha: CGFloat = dimmed ? 0.80 : 1.0
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            .paragraphStyle: para,
        ]
        let t = NSAttributedString(string: top, attributes: attrs)
        let b = NSAttributedString(string: bottom, attributes: attrs)
        let lineHeight = ceil(font.ascender - font.descender)
        let width = textWidth
        let height: CGFloat = 22
        let gap: CGFloat = -1   // tuck the lines together, as system readouts do
        let total = lineHeight * 2 + gap
        let originY = floor((height - total) / 2)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            b.draw(in: NSRect(x: 0, y: originY, width: width, height: lineHeight))
            t.draw(in: NSRect(x: 0, y: originY + lineHeight + gap, width: width, height: lineHeight))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Show / hide

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            close()
            showItemMenu()
            return
        }
        // The keyboard's live state: more reliable for status items than the
        // click event's own flags.
        let option = NSEvent.modifierFlags.contains(.option)
        if popover.isShown {
            close()
        } else if Date().timeIntervalSince(lastAutoClose) < 0.3 {
            // This same click already closed the popover as an outside click.
            Trace.log("item click ignored: popover was just closed by this click")
        } else {
            open(details: option)
        }
    }

    private func showItemMenu() {
        let menu = NSMenu()
        let about = NSMenuItem(title: "About BitPolish", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        let welcome = NSMenuItem(title: "Welcome to BitPolish", action: #selector(showWelcome), keyEquivalent: "")
        welcome.target = self
        menu.addItem(welcome)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BitPolish", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func quitFromMenu() { onQuit() }

    @objc private func showAbout() { AboutWindow.shared.show() }

    @objc private func showSettingsFromMenu() { showSettings() }

    @objc func showWelcome() { WelcomeWindow.shared.show { [weak self] in self?.showPanel() } }

    @objc private func checkForUpdates() { Updates.shared.checkForUpdates() }

    /// Reduce Motion: no roll-down or fades.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func animate(_ duration: Double, _ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: duration), change) }
    }

    #if BITPOLISH_TESTING
    func openForTesting(details: Bool = false) { open(details: details) }
    func closeForTesting() { close() }
    var popoverFrameForTesting: NSRect? { popover.contentViewController?.view.window?.frame }
    var popoverShownForTesting: Bool { popover.isShown }
    var populatedForTesting: Bool { panelState.populated }
    /// The live popover view, drawn to a PNG (what's actually on screen).
    func renderLiveForTesting(to path: String) {
        let view = hosting.view
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    /// Renders the panel as it stands (light and dark) to PNGs for review.
    func renderPanelForTesting(to directory: String, name: String) {
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // With BITPOLISH_MAX_HEIGHT, the popover's own layout at that
            // height (content scrolling above the pinned Quit row).
            let forced = ProcessInfo.processInfo.environment["BITPOLISH_MAX_HEIGHT"].flatMap(Double.init)
            let host = NSHostingView(rootView: CardView(session: session, state: panelState, onToggle: { _ in }, onQuit: {},
                                                        pinsFooter: forced != nil)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: forced.map { NSSize(width: PanelMetrics.cardWidth, height: $0) } ?? host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(directory)/panel-\(name)-\(scheme).png"))
        }
    }
    var itemScreenFrameForTesting: NSRect? { item.button?.window?.frame }
    func flipForTesting(_ on: Bool) { flipSwitch(on) }
    #endif

    /// Opens the panel under the menu-bar icon (the welcome's Get Started,
    /// and a click on the Dock icon).
    func showPanel() {
        guard item.isVisible else { offerReadout(); return }
        if !popover.isShown { open() }
    }

    /// Settings…: the panel with Details showing, as an Option-click opens it.
    func showSettings() {
        guard item.isVisible else { offerReadout(); return }
        if popover.isShown { close() }
        open(details: true)
    }

    // MARK: Readout in or out of the menu bar

    /// Whether the readout is in the menu bar (the Dock menu's Show in Menu Bar).
    var readoutShown: Bool { item.isVisible }

    func setReadoutShown(_ shown: Bool) { item.isVisible = shown }

    /// Out of the menu bar, the Dock icon stands in for it (see Dock).
    private func readoutVisibilityChanged(_ visible: Bool) {
        Trace.log("readout \(visible ? "in" : "out of") the menu bar")
        if !visible { close() }
        Dock.readoutHidden = !visible
        Dock.apply()
    }

    /// The panel needs the readout to open under; offer to put it back.
    private func offerReadout() {
        activateNow()
        let alert = NSAlert()
        alert.messageText = "BitPolish isn't in the menu bar"
        alert.informativeText = "Its panel opens from the readout in the menu bar. Show the readout again?"
        alert.addButton(withTitle: "Show in Menu Bar")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { setReadoutShown(true) }
    }

    /// The Dock menu's Bit-Perfect Listening item.
    func flipFromMenu(_ on: Bool) {
        guard !session.movingOutput else { return }
        flipSwitch(on)
    }

    private func open(details: Bool = false) {
        guard let button = item.button else { return }
        session.refreshDeviceState()
        session.panelWillOpen()   // before measuring: an expired notice goes now
        populateWork?.cancel()
        panelState.populated = session.isOn
        panelState.showDetails = details
        popover.animates = !reduceMotion
        popover.contentSize = NSSize(width: PanelMetrics.cardWidth, height: cardHeight())
        activateNow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // A size set while the popover was closed isn't always honored when it
        // shrinks (it kept the taller Details height after an Option-click),
        // so fit it again once it's on screen.
        DispatchQueue.main.async { [weak self] in
            self?.fitPopover()
            // No control starts with keyboard focus, as in Apple's menu-bar
            // panels (Wi-Fi, Sound): otherwise the switch opens wearing a
            // focus ring, which made it look oversized. Tab still moves focus.
            let window = self?.popover.contentViewController?.view.window
            window?.makeFirstResponder(nil)
        }
        Trace.log("popover shown")

        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" {
                self.onQuit()
                return nil
            }
            return event
        }
    }

    private func close() {
        if popover.isShown { popover.performClose(nil) }
        cleanUpAfterClose()
    }

    private func cleanUpAfterClose() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // NSPopoverDelegate: transient closes (outside click, Escape) land here.
    // Stamped when the close begins, so a click on the item during the close
    // animation counts as the closing click and doesn't reopen it.
    nonisolated func popoverWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastAutoClose = Date()
            NotificationCenter.default.post(name: .panelWillClose, object: nil)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            cleanUpAfterClose()
            panelState.showDetails = false   // Details are for that one opening
            Trace.log("popover closed")
        }
    }

    // MARK: The switch

    private func flipSwitch(_ on: Bool) {
        populateWork?.cancel()
        flipGeneration += 1
        let generation = flipGeneration
        Trace.log("switch \(on ? "On" : "Off")")
        if on {
            panelState.populated = false
            session.clearNotice()   // measure without it, so the height is final
            // 1. Roll down: the popover animates to the final height.
            setPopoverHeight(cardHeight(expanded: true))
            // 3. Fill in once both the roll-down and the device change are done.
            var rolled = false, ready = false
            let populate = { [weak self] in
                guard let self, rolled, ready, generation == self.flipGeneration else { return }
                Trace.log("populate")
                self.animate(0.3) { self.panelState.populated = true }
            }
            session.setOn(true) {
                Trace.log("device ready")
                ready = true
                // On the next pass, after the session's own updates (and the
                // refit they trigger) land: started inside that same pass,
                // the fade-in could stall with the panel left on the
                // "Setting …" overlay (Eli, 2026-10-19).
                DispatchQueue.main.async { populate() }
            }
            let work = DispatchWorkItem { rolled = true; populate() }
            populateWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + PanelMetrics.rollSeconds + 0.05, execute: work)
        } else {
            animate(0.2) {
                panelState.populated = false
                session.setOn(false) { Trace.log("device restored") }
            }
            setPopoverHeight(cardHeight())
        }
    }

    // MARK: Output menu

    /// The user picked another DAC while On: the panel stays expanded behind
    /// the status line while the session moves (the session does the device
    /// side).
    private func chooseOutput(_ choice: SessionController.OutputChoice) {
        Trace.log("output chosen: \(choice.name)")
        // A pick during a move between DACs would race it; picking the
        // current DAC is ignored in the session, so nothing redraws.
        guard !session.movingOutput, choice.id != session.device?.id else { return }
        if session.isOn { panelState.populated = false }
        session.chooseOutput(choice) { [weak self] in
            // Next pass, as in flipSwitch: a fade started inside the
            // session's update can stall.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.animate(0.3) { self.panelState.populated = self.session.isOn }
                self.fitPopover()
            }
        }
    }

    #if BITPOLISH_TESTING
    func chooseOutputForTesting(named name: String) {
        guard let c = session.outputs.first(where: { $0.name == name && $0.eligible }) else { Trace.log("no DAC named \(name)"); return }
        chooseOutput(c)
    }
    #endif

    // MARK: Sizing

    /// The card's final height. `expanded` measures the On layout before the
    /// switch has actually flipped.
    private func cardHeight(expanded: Bool = false) -> CGFloat {
        sizer.rootView = CardView(session: session, state: panelState, onToggle: { _ in }, onQuit: {},
                                  forceExpanded: expanded)
        return ceil(sizer.sizeThatFits(in: CGSize(width: PanelMetrics.cardWidth, height: 10_000)).height)
    }

    private func setPopoverHeight(_ wanted: CGFloat) {
        // Never taller than the screen below the menu bar (less room for the
        // popover's arrow and a margin); past that, the content scrolls above
        // the pinned Quit row.
        let height = min(wanted, maxPopoverHeight)
        let size = NSSize(width: PanelMetrics.cardWidth, height: height)
        guard popover.contentSize != size else { return }
        Trace.log("popover height \(Int(height))")
        popover.contentSize = size   // animated by the popover while shown
    }

    /// The tallest the popover may be on the menu bar's screen.
    private var maxPopoverHeight: CGFloat {
        #if BITPOLISH_TESTING
        if let forced = ProcessInfo.processInfo.environment["BITPOLISH_MAX_HEIGHT"].flatMap(Double.init) { return forced }
        #endif
        let screen = item.button?.window?.screen ?? NSScreen.main
        return (screen?.visibleFrame.height ?? 10_000) - 24
    }

    /// Refit to content changes (new track, note appearing).
    private func fitPopover() {
        guard popover.isShown else { return }
        setPopoverHeight(cardHeight())
    }
}
