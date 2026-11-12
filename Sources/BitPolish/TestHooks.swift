import AppKit
import Foundation
import BitPolishCore

// Developer testing hooks. They're compiled only into builds made with
// `./build.sh --testing`; normal and release builds contain only Trace's
// empty stub.

/// Timestamped event trace on stderr (`BITPOLISH_TRACE=1`, testing builds only).
enum Trace {
    #if BITPOLISH_TESTING
    private static let enabled = ProcessInfo.processInfo.environment["BITPOLISH_TRACE"] == "1"
    private static let start = Date()
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(String(format: "%7.3f  %@\n", Date().timeIntervalSince(start), message()).data(using: .utf8)!)
    }
    #else
    @inline(__always) static func log(_ message: @autoclosure () -> String) {}
    #endif
}

#if BITPOLISH_TESTING
@MainActor
enum TestHooks {
    private static func on(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }

    /// The Output pop-up button, so tests can find where it is on screen.
    static weak var outputButton: NSPopUpButton?
    /// `BITPOLISH_FAKE_RATES=all` or a comma list of Hz: the Manually Prime DAC section
    /// draws as if the DAC offered these rates. Display only.
    static var fakeRates: [Double]? {
        guard let v = ProcessInfo.processInfo.environment["BITPOLISH_FAKE_RATES"] else { return nil }
        return v == "all" ? Priming.standardRates : v.split(separator: ",").compactMap { Double($0) }
    }

    /// Where the panel's first ⓘ sits on screen, once laid out (PanelView's
    /// ScreenProbe sets it).
    static var firstInfoScreenFrame: NSRect?

    /// Behave as a standard (non-admin) account that can't read the log.
    static var simulateNoLog: Bool { on("BITPOLISH_SIMULATE_NO_LOG") }

    /// Save the menu-bar readout image as PNG (`BITPOLISH_DUMP_LABEL=<path>`).
    static func dumpLabel(_ image: NSImage?) {
        guard let path = ProcessInfo.processInfo.environment["BITPOLISH_DUMP_LABEL"],
              let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func install(session: SessionController, statusItem: StatusItemController) {
        func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
        }
        let env = ProcessInfo.processInfo.environment
        if on("BITPOLISH_START_ON") { session.setOn(true) }
        if on("BITPOLISH_OPEN_PANEL") { after(env["BITPOLISH_OPEN_DELAY"].flatMap(Double.init) ?? 1) { statusItem.openForTesting(details: on("BITPOLISH_DETAILS")) } }
        // For scripted click tests: write a control's screen center (top-left
        // origin, as CGEvent uses) to a file once it's on screen.
        func writeCenter(_ path: String, after delay: Double = 0.5, _ frame: @escaping @MainActor () -> NSRect?) {
            func poll() {
                guard let r = frame(), r.width > 0 else { after(0.25, poll); return }
                let screenH = NSScreen.screens.first?.frame.height ?? 0
                try? "\(Int(r.midX)) \(Int(screenH - r.midY))".write(toFile: path, atomically: true, encoding: .utf8)
            }
            after(delay, poll)
        }
        // The menu-bar item's position settles about a second after launch.
        if let path = env["BITPOLISH_ITEM_AT"] { writeCenter(path, after: 1) { statusItem.itemScreenFrameForTesting } }
        if let path = env["BITPOLISH_INFO_AT"] { writeCenter(path) { firstInfoScreenFrame } }
        if let path = env["BITPOLISH_OUTPUT_BUTTON_AT"] {
            writeCenter(path) {
                guard let b = outputButton, let w = b.window, w.isVisible else { return nil }
                return w.convertToScreen(b.convert(b.bounds, to: nil))
            }
        }
        if let dir = env["BITPOLISH_RENDER_WELCOME"] { renderWelcomeForTesting(to: dir) }
        if let dir = env["BITPOLISH_RENDER_ABOUT"] { renderAboutForTesting(to: dir) }
        // The panel's current state as PNGs at +4 s, after opening it
        // (BITPOLISH_RENDER_PANEL=<dir>; add BITPOLISH_DETAILS=1 for Option).
        // BITPOLISH_RENDER_AT=<s> renders later (e.g. after a session test's
        // Off, for the Return offer); BITPOLISH_RENDER_PICK=<DAC> picks that
        // DAC while Off first, for the move note (the Mac's output doesn't change).
        if let dir = env["BITPOLISH_RENDER_PANEL"] {
            if let name = env["BITPOLISH_RENDER_PICK"] {
                after(0.5) {
                    if let c = session.outputs.first(where: { $0.name == name && $0.eligible }) { session.pickOnTarget(c) } else { Trace.log("no DAC named \(name)") }
                }
            }
            after(1) { statusItem.openForTesting(details: on("BITPOLISH_DETAILS")) }
            after(env["BITPOLISH_RENDER_AT"].flatMap(Double.init) ?? 4) { statusItem.renderPanelForTesting(to: dir, name: "\(session.isOn ? "on" : "off")\(on("BITPOLISH_DETAILS") ? "-option" : "")") }
        }
        if on("BITPOLISH_WELCOME") { after(1) { WelcomeWindow.shared.show { statusItem.showPanel() } } }
        if on("BITPOLISH_ABOUT") { after(1) { AboutWindow.shared.show() } }
        if on("BITPOLISH_FLIP_TEST") {
            after(2) { statusItem.flipForTesting(true) }
            after(5) { statusItem.flipForTesting(false) }
        }
        // Off and quit in the same instant: the restore must still happen.
        if on("BITPOLISH_OFF_THEN_QUIT") {
            after(1.5) { statusItem.flipForTesting(true) }
            after(3) { statusItem.flipForTesting(false); NSApp.terminate(nil) }
        }
        // Switch On, then prime for the given rate at +3 s (Music must be
        // paused or stopped), e.g. BITPOLISH_PRIME_TEST=96000.
        if let rate = env["BITPOLISH_PRIME_TEST"].flatMap(Double.init) {
            after(1.5) { statusItem.flipForTesting(true) }
            after(3) { session.prime(rate) }
        }
        // Open with Details, close, reopen without: the popover must shrink.
        if on("BITPOLISH_REOPEN_TEST") {
            after(1) { statusItem.openForTesting(details: true) }
            after(3) { Trace.log("details open: \(statusItem.popoverFrameForTesting.map(NSStringFromRect) ?? "?")"); statusItem.closeForTesting() }
            after(4) { statusItem.openForTesting(details: false) }
            after(5.5) { Trace.log("reopened: \(statusItem.popoverFrameForTesting.map(NSStringFromRect) ?? "?")") }
        }
        // Switch On, then choose each named output in turn, 3 s apart
        // (BITPOLISH_OUTPUT_TEST="HIFI USB AUDIO|U2790B"; DACs only).
        // Skipped while Music plays, so nothing blares from the wrong device.
        if let names = env["BITPOLISH_OUTPUT_TEST"]?.split(separator: "|").map(String.init) {
            after(1.5) { statusItem.flipForTesting(true) }
            for (i, name) in names.enumerated() {
                after(4 + Double(i) * 3) {
                    guard !session.isPlaying else { Trace.log("Music is playing: output test skipped"); return }
                    statusItem.chooseOutputForTesting(named: name)
                }
                after(6 + Double(i) * 3) {
                    Trace.log("after choosing \(name): output \(session.caps?.name ?? "?"), On \(session.isOn), \(session.deviceBits)-bit/\(Format.rate(session.deviceRate))")
                }
            }
        }
        // Switch On, then lock at the given bit depth at +3 s and back to
        // 24-bit at +6 s (BITPOLISH_BITS_TEST=32).
        if let bits = env["BITPOLISH_BITS_TEST"].flatMap(Int.init) {
            after(1.5) { statusItem.flipForTesting(true) }
            after(3) { session.setLockedBitDepth(bits) }
            after(6) { session.setLockedBitDepth(24) }
        }
        // A session from the current output: On at +2 s, Off at +5 s, then the
        // return offer is traced and, with BITPOLISH_RETURN=1, taken at +7 s
        // (BITPOLISH_SESSION_TEST=1). With BITPOLISH_SESSION_QUIT=1, quit at
        // +5 s instead of switching Off.
        if on("BITPOLISH_SESSION_TEST") {
            after(2) {
                guard !session.isPlaying else { Trace.log("Music is playing: session test skipped"); return }
                statusItem.flipForTesting(true)
            }
            if on("BITPOLISH_SESSION_QUIT") {
                after(5) { NSApp.terminate(nil) }
            } else {
                after(5) { statusItem.flipForTesting(false) }
                after(6.5) { Trace.log("return offer: \(session.returnOffer.map { "\($0.from) -> \($0.to)" } ?? "none")") }
                if on("BITPOLISH_RETURN") { after(7) { session.returnToOriginalOutput() } }
            }
        }
        // Act as if Music started a track at this rate, at +2.5 s
        // (BITPOLISH_FAKE_TRACK=96000).
        if let rate = env["BITPOLISH_FAKE_TRACK"].flatMap(Double.init) {
            after(2.5) { session.simulateTrackForTesting(rate) }
        }
        // Keep On: switch Off at +4 s, then act as if the DAC were replugged
        // at +5 s (BITPOLISH_RECONNECT_TEST=1).
        if on("BITPOLISH_RECONNECT_TEST") {
            after(4) { statusItem.flipForTesting(false); Trace.log("switched off for the test") }
            after(5) { session.simulateDACReconnectForTesting() }
            after(8) { Trace.log("after reconnect: On \(session.isOn)") }
        }
        // Show in Dock with the Details panel open: on at +2 s, off at +5 s;
        // the panel must stay open through both (BITPOLISH_DOCK_TEST=1).
        if on("BITPOLISH_DOCK_TEST") {
            func report(_ label: String) {
                Trace.log("\(label): policy \(NSApp.activationPolicy() == .regular ? "regular" : "accessory"), saved \(session.showsInDock), panel \(statusItem.popoverFrameForTesting != nil ? "open" : "closed"), active \(NSApp.isActive)")
            }
            after(1) { statusItem.openForTesting(details: true) }
            after(1.8) { report("before") }
            after(2) { session.setShowsInDock(true) }
            after(3.5) { report("after Show in Dock on") }
            after(5) { session.setShowsInDock(false) }
            after(6.5) { report("after Show in Dock off") }
        }
        // Off-mode pick: choose the named DAC at +1.5 s while Off (the Mac's
        // output must not change), switch On at +3 s, Off at +7 s
        // (BITPOLISH_PICK_TEST=<DAC name>).
        if let name = env["BITPOLISH_PICK_TEST"] {
            func report(_ label: String) {
                Trace.log("\(label): Mac output \(AudioDevice.defaultOutput().map { AudioDevice(id: $0.id).name } ?? "none"), target \(session.onTarget?.name ?? "none"), preview \(session.targetCaps?.name ?? "none"), On \(session.isOn), return \(session.returnOffer.map { "\($0.from) -> \($0.to)" } ?? "none")")
            }
            after(1.2) { report("before pick") }
            after(1.5) {
                if let c = session.outputs.first(where: { $0.name == name && $0.eligible }) { session.pickOnTarget(c) } else { Trace.log("no DAC named \(name)") }
            }
            after(2.5) { report("after pick") }
            after(3) { statusItem.flipForTesting(true) }
            after(6) { report("On") }
            after(7) { statusItem.flipForTesting(false) }
            after(9) { report("Off") }
        }
        // Eli's stuck "Setting …" report: open, On, Off, close, open, On
        // (BITPOLISH_STUCK_TEST=1).
        if on("BITPOLISH_STUCK_TEST") {
            func report(_ label: String) { Trace.log("\(label): On \(session.isOn), populated \(statusItem.populatedForTesting), shown \(statusItem.popoverShownForTesting)") }
            let fast = on("BITPOLISH_STUCK_FAST")   // second On during the slow restore
            after(1) { statusItem.openForTesting() }
            after(2) { statusItem.flipForTesting(true) }
            after(4) { report("after On") }
            after(5) { statusItem.flipForTesting(false) }
            after(fast ? 5.4 : 6.5) { report("after Off") }
            after(fast ? 5.6 : 7) { statusItem.closeForTesting() }
            after(fast ? 6.2 : 8) { statusItem.openForTesting() }
            after(fast ? 6.7 : 9) { statusItem.flipForTesting(true) }
            after(12) { report("after second On") }
            if let dir = env["BITPOLISH_RENDER_PANEL_LIVE"] {
                after(4.1) { statusItem.renderLiveForTesting(to: "\(dir)/live-first-on.png") }
                after(12.1) { statusItem.renderLiveForTesting(to: "\(dir)/live-second-on.png") }
            }
        }
        // Open at login: add at +2 s, report, remove at +4 s (BITPOLISH_LOGIN_TEST=1).
        if on("BITPOLISH_LOGIN_TEST") {
            after(2) { session.setOpensAtLogin(true); Trace.log("login item added: \(session.opensAtLogin), needs approval \(session.loginItemNeedsApproval), notice \(session.notice ?? "none")") }
            after(4) { session.setOpensAtLogin(false); Trace.log("login item removed: enabled now \(session.opensAtLogin)") }
        }
        // Notices expire by kind (spec v1.11), on a clock moved forward: an
        // event shown, then reopened at +4 and +6 minutes; an unseen event
        // at +25 hours; pending and action notices at +25 hours, with no DAC
        // in use (BITPOLISH_NOTICE_TEST=1; quits itself).
        if on("BITPOLISH_NOTICE_TEST") {
            func show(_ label: String) {
                statusItem.openForTesting()
                Trace.log("\(label): notice \(session.notice.map { "\"\($0)\"" } ?? "none")")
            }
            func advance(_ seconds: TimeInterval) { session.clockOffsetForTesting += seconds }
            after(1) { session.postNoticeForTesting("Event A", .event, about: "Test DAC"); show("event, first showing") }
            after(1.5) { statusItem.closeForTesting() }
            after(2) { advance(4 * 60); show("event, reopened 4 min later") }
            after(2.5) { statusItem.closeForTesting() }
            after(3) { advance(2 * 60); show("event, reopened 6 min after first showing") }
            after(3.5) { statusItem.closeForTesting() }
            after(4) { session.postNoticeForTesting("Event B", .event); advance(25 * 3600); show("event never shown, 25 h later") }
            after(4.5) { statusItem.closeForTesting() }
            after(5) { session.postNoticeForTesting("Pending C", .pending, about: "Test DAC"); show("pending, first showing") }
            after(5.5) { statusItem.closeForTesting() }
            after(6) { advance(25 * 3600); show("pending, 25 h later, no other DAC in use") }
            after(6.5) { statusItem.closeForTesting() }
            after(7) { session.postNoticeForTesting("Action D", .action); show("action, first showing") }
            after(7.5) { statusItem.closeForTesting() }
            after(8) { advance(25 * 3600); show("action, 25 h later") }
            after(8.5) { statusItem.closeForTesting(); NSApp.terminate(nil) }
        }
        // The readout out of or back in the menu bar, as ⌘-drag or the Dock
        // menu would (BITPOLISH_READOUT=hide|show|report): reports at +1 s,
        // acts at +1.5 s, reports at +2.5 s, quits at +3 s. Hide, then
        // report, checks the choice survives a relaunch.
        if let action = env["BITPOLISH_READOUT"] {
            func report(_ label: String) {
                Trace.log("\(label): readout \(statusItem.readoutShown ? "in menu bar" : "out"), policy \(NSApp.activationPolicy() == .regular ? "regular (Dock icon)" : "accessory"), Show in Dock \(Dock.isShown)")
            }
            after(1) { report("at launch") }
            if action != "report" { after(1.5) { statusItem.setReadoutShown(action == "show") } }
            after(2.5) { report("after \(action)") }
            after(3) { NSApp.terminate(nil) }
        }
        // On/Off three times, 150 ms apart.
        if on("BITPOLISH_RAPID_TEST") {
            for (i, flip) in [true, false, true, false, true, false].enumerated() {
                after(1.5 + Double(i) * 0.15) { statusItem.flipForTesting(flip) }
            }
        }
    }
}
#endif
