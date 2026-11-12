import AppKit
import CoreAudio
import BitPolishCore
import SwiftUI

// The 27 SDK's @State macro needs Xcode's SwiftUIMacros plugin, which Command Line Tools don't ship; this keeps BitPolish buildable without Xcode (revisit if a later CLT release includes it).
typealias ViewState = SwiftUI.State

/// The native look: the popover's own translucent material behind
/// everything, system text colors (so text is vibrant and follows Increase
/// Contrast and Light/Dark mode), system separators, and system green and
/// orange for state.
enum Look {
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    /// Section labels, like a system menu's section headers.
    static let sectionFont = Font.system(size: 11, weight: .semibold)
    static let inset: CGFloat = 14
    /// A section's padding: the inset at the sides, a little less above and
    /// below, so a full panel (Details open) fits smaller screens.
    static let section = EdgeInsets(top: 12, leading: inset, bottom: 12, trailing: inset)
}

/// Layout constants shared by the card and the popover controller.
enum PanelMetrics {
    static let cardWidth: CGFloat = 320
    /// How long the popover takes to roll down before the details fade in.
    static let rollSeconds: TimeInterval = 0.38
}

/// Whether the details are filled in yet (see StatusItemController's
/// staging), and whether the panel was opened with Option held.
@MainActor
final class PanelState: ObservableObject {
    @Published var populated: Bool
    @Published var showDetails = false
    init(populated: Bool) { self.populated = populated }
}

/// The panel's content.
struct CardView: View {
    @ObservedObject var session: SessionController
    @ObservedObject var state: PanelState
    var onToggle: (Bool) -> Void
    var onQuit: () -> Void
    var onAbout: () -> Void = {}
    var onChooseOutput: (SessionController.OutputChoice) -> Void = { _ in }
    /// For measuring: lay out as if On, before the switch actually flips.
    var forceExpanded = false

    @ObservedObject private var updates = Updates.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { forceExpanded || session.isOn || session.movingOutput }

    /// The Off-only rows (the move note, the Return offer, the Accepts
    /// preview), left out when measuring the On layout before the switch
    /// flips, so the roll-down goes straight to its final height.
    private var showsOffRows: Bool { !session.isOn && !forceExpanded }

    /// In the popover: the content scrolls if it ever runs out of room, and
    /// Quit and About stay pinned at the bottom (as the Wi-Fi menu keeps its
    /// settings row). Measuring and rendering lay it out whole.
    var pinsFooter = false

    var body: some View {
        VStack(spacing: 0) {
            if pinsFooter {
                ScrollView(.vertical) { main }
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                main
            }
            separator
            PanelFooter(availableVersion: updates.availableVersion, onQuit: onQuit, onAbout: onAbout)
        }
        .frame(width: PanelMetrics.cardWidth, alignment: .top)
    }

    private var main: some View {
        VStack(spacing: 0) {
            switchRow
            if showsOffRows {
                if let target = session.onTarget, let caps = session.caps, target.id != caps.id {
                    noteRow("The Mac's sound is on \(caps.name). Turning on switches it to \(target.name). Turn it down first if it feeds an amp.", color: .secondary)
                } else if session.onTarget == nil, let reason = session.caps?.ineligibleReason {
                    noteRow(reason, color: .secondary)
                }
            }
            if showsOffRows, let offer = session.returnOffer {
                returnRow(offer)
            }
            if session.logUnavailable {
                noteRow("Following each track's sample rate needs an administrator account. macOS only lets admin accounts read the system log, which is how BitPolish learns each track's format. The bit-depth lock still works.", color: Look.orange)
            }
            if let notice = session.notice {
                noteRow(notice, color: .secondary)
            }
            if expanded {
                details
                    .opacity(state.populated ? 1 : 0)
                    .overlay(alignment: .center) {
                        if !state.populated {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(session.settingUpText).font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                        }
                    }
                    .transition(.opacity)
            } else {
                tail
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: session.file)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: session.unsupportedNote)
    }

    private var details: some View {
        let rows = primingRows
        let name = session.caps?.name
        return VStack(spacing: 0) {
            separator
            HeaderSection(isPlaying: session.isPlaying, deviceRate: session.deviceRate, deviceBits: session.deviceBits,
                          track: session.track, primedRate: session.primedRate, isBitPerfect: session.isBitPerfect,
                          unsupportedNote: session.unsupportedNote, volumeFull: session.deviceVolumeFull,
                          deviceName: name, topBitDepth: session.bitDepthChoices.max())
            separator
            BitDepthRow(choices: session.bitDepthChoices, locked: session.lockedBitDepth,
                        deviceName: name, session: session)
            if !rows.isEmpty {
                separator
                PrimingSection(rows: rows, deviceRate: session.deviceRate, canPrime: session.canPrime,
                               isPlaying: session.isPlaying, deviceName: name, session: session)
            }
            if session.file != nil || session.isStream {
                separator
                FileSection(file: session.file)
            }
            tail
        }
    }

    /// The bottom of the panel's content, the same in both states: Output,
    /// then Details (Option-click), or while Off the DAC's Accepts list as a
    /// preview (while On the Manually Prime DAC buttons show it). Quit and
    /// About follow, pinned (see `body`).
    @ViewBuilder private var tail: some View {
        separator
        OutputRow(isOn: session.isOn, dacs: session.outputs.filter(\.eligible), deviceID: session.device?.id,
                  deviceName: session.caps?.name, target: session.onTarget,
                  onChooseOutput: onChooseOutput, session: session)
        if state.showDetails {
            separator
            DetailsSection(session: session, acceptsLines: acceptsLines)
        } else if showsOffRows, !(session.targetCaps?.accepts.isEmpty ?? true) {
            separator
            AcceptsBlock(lines: acceptsLines).padding(Look.section)
        }
    }

    private var separator: some View { Divider().padding(.horizontal, Look.inset) }

    /// A full-width line of explanation under a separator.
    @ViewBuilder private func noteRow(_ text: String, color: Color) -> some View {
        separator
        Text(text).font(.callout).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(Look.section)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var switchRow: some View {
        HStack {
            Text("Bit-Perfect Listening").font(.body.weight(.semibold))
            Spacer()
            Toggle("Bit-Perfect Listening", isOn: Binding(get: { session.isOn }, set: { onToggle($0) }))
                .toggleStyle(.switch).labelsHidden()
                .disabled(session.movingOutput || (!session.isOn && !session.canActivate))
        }
        .padding(Look.section)
    }

    /// After a session that started on the speakers (or another non-DAC
    /// output), sound stays on the DAC until you choose to go back.
    @ViewBuilder private func returnRow(_ offer: (from: String, to: String)) -> some View {
        separator
        VStack(alignment: .leading, spacing: 8) {
            Text("Sound is still on \(offer.from).").font(.callout).foregroundStyle(.secondary)
            Button("Return to \(offer.to)") { session.returnToOriginalOutput() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Look.section)
    }

    private var primingRows: [PrimingRow] {
        var supported = session.caps?.rates ?? []
        #if BITPOLISH_TESTING
        // Draw the layout as if the DAC offered these rates (display only).
        if let fake = TestHooks.fakeRates { supported = fake }
        #endif
        return PrimingRow.rows(supported: supported)
    }

    /// While On, the DAC in use; while Off, the DAC switching On will use
    /// (or, with no DAC, the current output, for the Option view).
    private var acceptsLines: [String] {
        (session.isOn ? session.caps : session.targetCaps ?? session.caps)?.accepts ?? []
    }
}

/// The popover's content: the card pinned to the top, over the popover's
/// own material (the popover's frame does the rolling).
struct PopoverContent: View {
    @ObservedObject var session: SessionController
    @ObservedObject var state: PanelState
    var onToggle: (Bool) -> Void
    var onQuit: () -> Void
    var onAbout: () -> Void = {}
    var onChooseOutput: (SessionController.OutputChoice) -> Void = { _ in }

    var body: some View {
        CardView(session: session, state: state, onToggle: onToggle, onQuit: onQuit, onAbout: onAbout,
                 onChooseOutput: onChooseOutput, pinsFooter: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A Manually Prime DAC row: one rate family, identified by its base rate
/// (44.1 or 48 kHz), so each row keeps its identity whatever is shown.
/// Equatable, so PrimingSection is skipped when its rows haven't changed.
struct PrimingRow: Identifiable, Equatable {
    let id: Double
    let cells: [Priming.Cell]

    /// `Priming.rows` builds its rows in `Priming.families` order.
    static func rows(supported: [Double]) -> [PrimingRow] {
        zip(Priming.families, Priming.rows(supported: supported)).map { PrimingRow(id: $0[0], cells: $1) }
    }
}

/// A thin rectangular rate button for Manually Prime DAC. The DAC's current rate
/// gets a filled, outlined box. While Music plays the buttons can't be
/// pressed, but stay brighter than the unsupported rates under them.
struct PrimeButton: View {
    let rate: Double
    let supported: Bool
    let current: Bool
    let enabled: Bool
    let action: () -> Void
    @ViewState private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var highContrast: Bool { contrast == .increased }

    private var fill: Color {
        if current { return Color.primary.opacity(0.14) }
        return hovering && enabled && supported ? Color.primary.opacity(0.07) : .clear
    }

    private var stroke: Color {
        if current { return Color.primary.opacity(highContrast ? 0.9 : 0.5) }
        if !supported { return Color.primary.opacity(highContrast ? 0.3 : 0.08) }
        return highContrast ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor)
    }

    var body: some View {
        // Not `.disabled`: SwiftUI dims a disabled button's label, which made
        // the current rate harder to read. The press is ignored instead.
        Button { if enabled && supported && !current { action() } } label: {
            Text(Format.rate(rate))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(!supported ? AnyShapeStyle(.tertiary)
                                 : current || enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(RoundedRectangle(cornerRadius: 4).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(supported ? "Prime for \(Format.rate(rate)) kilohertz" : "\(Format.rate(rate)) kilohertz, not accepted")
        .accessibilityValue(current ? "Current rate" : "")
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityHint(!supported || enabled || current ? "" : "Pause Music to prime")
    }
}

/// Text that acts as a link: secondary (or primary) at rest, underlined
/// and full strength while the pointer is over it.
struct HoverLink: View {
    let label: String
    var font: Font = .footnote
    var primary = false
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label).underline(hovering).lineLimit(1).truncationMode(.tail)
            .font(font)
            .foregroundStyle(primary || hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small borderless AppKit pop-up button for a short list of choices
/// (the bit depth), sized to the selected title.
struct ChoicePopUp: NSViewRepresentable {
    let titles: [String]
    let selected: Int
    let onPick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FittedPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onPick = onPick
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if button.indexOfSelectedItem != selected { button.selectItem(at: selected) }
        button.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject {
        var onPick: (Int) -> Void = { _ in }
        @MainActor @objc func picked(_ sender: NSPopUpButton) {
            sender.invalidateIntrinsicContentSize()
            onPick(sender.indexOfSelectedItem)
        }
    }
}

/// A pop-up button sized to its selected title rather than the longest item,
/// so it sits at a row's right edge like a label.
final class FittedPopUpButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        let title = (selectedItem?.title ?? "") as NSString
        let width = title.size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        return NSSize(width: ceil(width) + 26, height: super.intrinsicContentSize.height)
    }
}

/// A borderless AppKit pop-up button listing the DACs, opening with the
/// current one over the button, as every Mac pop-up button does.
struct OutputPopUp: NSViewRepresentable {
    let outputs: [SessionController.OutputChoice]
    let current: AudioDeviceID?
    let currentName: String
    let onPick: (SessionController.OutputChoice) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FittedPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.menu?.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.picked(_:))
        button.setAccessibilityLabel("DAC")
        #if BITPOLISH_TESTING
        TestHooks.outputButton = button
        #endif
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.outputs = outputs
        context.coordinator.current = current
        let signature = outputs.map { "\($0.id)|\($0.name)" } + ["current:\(current ?? 0)"]
        guard signature != context.coordinator.signature else { return }
        context.coordinator.signature = signature

        let menu = button.menu ?? NSMenu()
        menu.removeAllItems()
        func add(_ c: SessionController.OutputChoice) {
            let item = NSMenuItem(title: c.name, action: nil, keyEquivalent: "")
            item.representedObject = c.id
            menu.addItem(item)
        }
        outputs.forEach(add)
        if let item = menu.items.first(where: { ($0.representedObject as? AudioDeviceID) == current }) {
            button.select(item)
        } else {
            // The output isn't in the list yet (just plugged in): show its name.
            let item = NSMenuItem(title: currentName, action: nil, keyEquivalent: "")
            menu.insertItem(item, at: 0)
            button.select(item)
        }
        button.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject {
        var onPick: (SessionController.OutputChoice) -> Void = { _ in }
        var outputs: [SessionController.OutputChoice] = []
        var current: AudioDeviceID?
        var signature: [String] = []

        @MainActor @objc func picked(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? AudioDeviceID,
                  let choice = outputs.first(where: { $0.id == id }) else { return }
            signature = []   // re-sync the selection with what actually happens
            sender.invalidateIntrinsicContentSize()
            onPick(choice)
        }
    }
}

/// A full-width row that highlights under the pointer, like a menu item.
struct MenuRow: View {
    let title: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension Notification.Name {
    /// The panel is closing: ⓘ bubbles drop a pending hover and close.
    static let panelWillClose = Notification.Name("BitPolish.panelWillClose")
}

/// An ⓘ that shows its explanation: on hover after macOS's tooltip delay,
/// at once on click, and from the keyboard and VoiceOver (it's a real
/// button, labeled, with the text as its hint). No `.help` tooltip: it would
/// show a second copy of the text over the bubble.
struct InfoButton: View {
    let text: String
    @ViewState private var showing = false
    @ViewState private var pending: Task<Void, Never>?

    /// macOS's tooltip delay: 1.5 s, or the user's `NSInitialToolTipDelay`
    /// (milliseconds) if they've set one.
    static var hoverDelay: TimeInterval {
        let ms = UserDefaults.standard.double(forKey: "NSInitialToolTipDelay")
        return ms > 0 ? ms / 1000 : 1.5
    }
    /// As with tooltips, once one bubble has been showing, the next one
    /// within this window appears at once. (A closing bubble delays the next
    /// hover event by about 0.7 s, so 1 s.)
    @MainActor static var lastHidden = Date.distantPast
    static let quickWindow: TimeInterval = 1.0
    /// Made once, so every redraw sees the same publisher.
    private static let panelClosing = NotificationCenter.default.publisher(for: .panelWillClose)

    var body: some View {
        Button { pending?.cancel(); showing.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            pending?.cancel()
            if inside {
                let quick = Date().timeIntervalSince(Self.lastHidden) < Self.quickWindow
                if quick { showing = true; return }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Self.hoverDelay))
                    if !Task.isCancelled { showing = true }
                }
            } else if showing {
                showing = false
                Self.lastHidden = Date()
            }
        }
        // A hover's exit may never arrive once the panel's window closes, so
        // a pending bubble could open later on a closed or reopened panel.
        .onReceive(Self.panelClosing) { _ in
            pending?.cancel()
            pending = nil
            showing = false
        }
        .accessibilityLabel("More information")
        .accessibilityHint(text)
        #if BITPOLISH_TESTING
        .background(ScreenProbe())
        #endif
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .lineLimit(nil)
                .padding(14).frame(width: 280).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if BITPOLISH_TESTING
/// Testing only: records where the first ⓘ sits on screen once it's in a
/// visible window (for BITPOLISH_INFO_AT).
private struct ScreenProbe: NSViewRepresentable {
    final class Probe: NSView {
        override func layout() {
            super.layout()
            guard TestHooks.firstInfoScreenFrame == nil, let w = window, w.isVisible, bounds.width > 0 else { return }
            TestHooks.firstInfoScreenFrame = w.convertToScreen(convert(bounds, to: nil))
        }
        override func viewDidMoveToWindow() { needsLayout = true }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
#endif
