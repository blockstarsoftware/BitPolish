import AppKit
import SwiftUI

/// BitPolish's About window. macOS's standard About panel can't hold a button,
/// so this matches its layout and adds Check for Updates…. One at a time;
/// Escape or ⌘W closes it.
@MainActor
final class AboutWindow {
    static let shared = AboutWindow()
    private var window: NSWindow?

    /// The project's source code; the link is hidden when nil.
    static let sourceURL: URL? = URL(string: "https://github.com/blockstarsoftware/BitPolish")

    /// The App Store's icon, read from the system when About opens, so no
    /// Apple artwork ships with BitPolish. Nil if it can't be found.
    static var appStoreIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func show() {
        ClosableWindow.present(&window, title: "About BitPolish", content: AboutView())
    }
}

private struct AboutView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var name: String { info["CFBundleName"] as? String ?? "BitPolish" }
    private var version: String {
        "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }
    private var copyright: String { info["NSHumanReadableCopyright"] as? String ?? "" }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(name).font(.title2.weight(.bold))
            Text("by Blockstar Software").font(.callout).foregroundStyle(.secondary)
            Text(version).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Bit-perfect playback of your local Apple Music library through an external DAC.")
                .font(.callout).multilineTextAlignment(.center).padding(.top, 6)
            Text(copyright).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                .padding(.top, 10)
            if let url = AboutWindow.sourceURL {
                Link("Source code", destination: url).font(.caption)
            }
            HStack(spacing: 6) {
                Text("🖥️ 🍑 🖥️").font(.callout)
                if let icon = AboutWindow.appStoreIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                }
            }
            .padding(.top, 12)
            // Pay-it-forward note: the money goes to the nonprofit, which
            // isn't affiliated with the app.
            (Text("Enjoying \(name)? Pass the goodwill on. Donate to ").foregroundStyle(.secondary)
             + Text(.init("[Unconditional Freedom](\(Donation.url.absoluteString))"))
             + Text(", \(Donation.tail)").foregroundStyle(.secondary))
                .font(.caption).multilineTextAlignment(.center).padding(.top, 6)
        }
        .frame(width: 300)
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
        .fixedSize()
    }
}

#if BITPOLISH_TESTING
/// Renders the About window's content, light and dark, as PNGs for review.
/// Drawn through an AppKit hosting view, so native controls render as they
/// do on screen.
@MainActor
func renderAboutForTesting(to directory: String) {
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let host = NSHostingView(rootView: AboutView())
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(directory)/about-\(name).png"))
    }
}
#endif
