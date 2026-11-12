import AppKit
import SwiftUI

/// The welcome window, shown once: on the very first launch, never after an
/// update (the "shown" flag lives in BitPolish's preferences, which updates
/// keep). It explains where BitPolish lives, how to use it, updates, and a
/// pay-it-forward donation. Get Started opens the panel under the menu-bar
/// icon, so the first click teaches where the app is.
@MainActor
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private static let shownKey = "WelcomeShown"
    private var window: NSWindow?

    /// Shows the welcome if it has never been shown on this Mac.
    func showIfFirstLaunch(openPanel: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        show(openPanel: openPanel)
    }

    func show(openPanel: @escaping () -> Void) {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        ClosableWindow.present(&window, title: "Welcome to BitPolish", content: WelcomeView(getStarted: { [weak self] in
            self?.window?.close()
            openPanel()
        }))
    }
}

private struct WelcomeView: View {
    let getStarted: () -> Void

    private func paragraph(_ markdown: String) -> some View {
        Text(.init(markdown)).fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Welcome to BitPolish").font(.title.weight(.bold))
                Text("Bit-perfect playback of your local Apple Music library through an external DAC.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            section("Where It Lives") {
                paragraph("BitPolish lives in your menu bar, as a small icon showing your DAC's format (for example \"16-bit / 44.1 kHz\"). Click it to open the panel.")
                paragraph("If you can't see the icon, your menu bar may be full: quit an item or two, or hold ⌘ and drag BitPolish's icon to a visible spot.")
                    .foregroundStyle(.secondary)
            }

            section("Getting Started") {
                VStack(alignment: .leading, spacing: 4) {
                    paragraph("1. Switch on **Bit-Perfect Listening**. If the Mac's sound isn't already on your DAC, BitPolish switches it there, so turn your DAC or amp down first.")
                    paragraph("2. Set the Mac's volume and Music's volume to 100%, and use your DAC or amp for listening level.")
                    paragraph("3. Play your library in Apple Music.")
                }
                paragraph("Switch it off or quit when you're done; your DAC goes back to exactly how it was. If BitPolish moved your sound to the DAC, it stays there until you click **Return** in the panel, so nothing suddenly plays through your speakers.")
                    .foregroundStyle(.secondary)
            }

            section("Updates") {
                paragraph("BitPolish is updated from time to time and checks for new versions once a day while it's running. To check yourself, click **Check for Updates…** in **About**, at the bottom of the panel.")
            }

            section("Pay It Forward") {
                paragraph("BitPolish is free. If it finds a place in your listening routine, pass the goodwill on with a donation to Unconditional Freedom, \(Donation.tail)")
                DonateCard().padding(.top, 4)
            }

            HStack {
                Spacer()
                Button("Get Started", action: getStarted)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .font(.callout)
        .frame(width: 420)
        .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)
        .fixedSize()
    }
}

/// A donate button in Unconditional Freedom's own style: their ×/+ mark and
/// wordmark on their cream, with a square dark DONATE label. The whole card
/// is the link. In Dark Mode the colors invert, as on a dark page.
private struct DonateCard: View {
    @Environment(\.colorScheme) private var scheme
    @ViewState private var hovering = false

    private var paper: Color { scheme == .dark ? Color(red: 39/255, green: 34/255, blue: 32/255) : Color(red: 245/255, green: 241/255, blue: 235/255) }
    private var ink: Color { scheme == .dark ? Color(red: 245/255, green: 241/255, blue: 235/255) : Color(red: 39/255, green: 34/255, blue: 32/255) }

    var body: some View {
        Link(destination: Donation.url) {
            HStack(spacing: 14) {
                UFMark().fill(Color(red: 150/255, green: 146/255, blue: 142/255))
                    .frame(width: 38, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UNCONDITIONAL")
                    Text("FREEDOM.ORG")
                }
                .font(.system(size: 12, weight: .medium)).tracking(1.6)
                .foregroundStyle(ink)
                Spacer()
                Text("DONATE")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(paper)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Rectangle().fill(ink.opacity(hovering ? 0.85 : 1)))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8).fill(paper))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Opens \(Donation.url.host() ?? "")\(Donation.url.path())")
        .accessibilityLabel("Donate to Unconditional Freedom")
    }
}

/// Unconditional Freedom's ×/+ mark, drawn from its proportions (709 × 375).
private struct UFMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 709, sy = rect.height / 375
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        // ×: two crossed bars.
        path.addLines([p(0, 120), p(45, 75), p(117, 147), p(189, 75), p(234, 120), p(162, 192),
                       p(234, 264), p(189, 309), p(117, 237), p(45, 309), p(0, 264), p(72, 192)])
        path.closeSubpath()
        // /: a slanted bar.
        path.addLines([p(377, 0), p(452, 0), p(326, 375), p(251, 375)])
        path.closeSubpath()
        // +: crossed bars.
        path.addLines([p(545, 60), p(610, 60), p(610, 160), p(709, 160), p(709, 224), p(610, 224),
                       p(610, 323), p(545, 323), p(545, 224), p(446, 224), p(446, 160), p(545, 160)])
        path.closeSubpath()
        return path
    }
}

#if BITPOLISH_TESTING
/// Testing only: renders the welcome to PNG files (light and dark).
@MainActor
func renderWelcomeForTesting(to directory: String) {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let view = WelcomeView(getStarted: {})
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
        try? png.write(to: URL(fileURLWithPath: "\(directory)/welcome-\(name).png"))
    }
}
#endif
