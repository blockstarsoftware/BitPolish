import AppKit
import SwiftUI

/// Makes BitPolish the active app right away. `NSApp.activate()` is only a
/// request on macOS 14 and later, and for a menu-bar app the system grants it
/// at the first click inside BitPolish's window instead; that late activation
/// closed any menu the same click opened (the Output menu flickered shut on
/// its first click). The older call still activates immediately.
@MainActor
func activateNow() {
    NSApp.activate(ignoringOtherApps: true)
}

/// The small standalone windows (About, Welcome): a hidden-titlebar window
/// that closes with Escape and ⌘W (a menu-bar app has no app menu to
/// provide ⌘W).
final class ClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Shows `content` in `window` (created on first use), sized to fit,
    /// centered and in front, with nothing focused, as Apple's own windows
    /// open (Tab still moves focus; Return still presses the default button).
    @MainActor
    static func present<Content: View>(_ window: inout NSWindow?, title: String, content: Content) {
        if window == nil {
            let w = ClosableWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            window = w
        }
        guard let w = window else { return }
        w.title = title
        w.contentViewController = NSHostingController(rootView: content)
        w.setContentSize(w.contentViewController?.view.fittingSize ?? NSSize(width: 400, height: 400))
        w.center()
        activateNow()
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }
}

/// Unconditional Freedom, the nonprofit BitPolish's About and Welcome windows
/// point to (unaffiliated with the app).
enum Donation {
    static let url = URL(string: "https://unconditionalfreedom.org/donate")!
    /// Ends the donation sentence in both windows.
    static let tail = "a 501(c)(3) that supports human flourishing for all. Donations go to them, not to me or this app."
}
