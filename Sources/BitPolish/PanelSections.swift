import AppKit
import CoreAudio
import BitPolishCore
import ServiceManagement
import SwiftUI

// The panel's sections, each its own view holding only the values it shows,
// so SwiftUI skips a section whose values haven't changed. CardView reads the
// session and passes the values down. A section's `session` is for actions
// only: a section that read state through it would miss updates, since it
// doesn't observe the session. (DetailsSection is the exception; it observes.)

/// A section's label, like a system menu's section headers.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Look.sectionFont).foregroundStyle(.secondary)
    }
}

// MARK: Header

/// The big number is what goes to the DAC, matching the menu bar. The
/// Source → DAC rows underneath show where that differs from the file.
struct HeaderSection: View {
    let isPlaying: Bool
    let deviceRate: Double
    let deviceBits: Int
    let track: TrackFormat?
    let primedRate: Double?
    let isBitPerfect: Bool
    let unsupportedNote: String?
    let volumeFull: Bool
    /// For the ⓘ text: the output's name and the highest bit depth it offers.
    let deviceName: String?
    let topBitDepth: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(badgeColor).frame(width: 7, height: 7)
                Text(badge).font(Look.sectionFont).foregroundStyle(badgeColor).lineLimit(1)
                Spacer(minLength: 8)
                Text(isPlaying ? "Apple Music · Playing" : "Apple Music · Idle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("To DAC").padding(.top, 6)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.rate(deviceRate))
                        .font(.system(size: 56, weight: .regular)).monospacedDigit()
                    Text("kHz").font(.title3).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("To DAC: \(Format.rate(deviceRate)) kilohertz")
            if let note = unsupportedNote {
                Text(note).font(.callout).foregroundStyle(Look.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            pathRow
            VolumeReminder(full: volumeFull).padding(.top, 4)
        }
        .padding(Look.section)
    }

    /// The device differs from the track because macOS is resampling (a
    /// deliberately primed rate doesn't count).
    private var rateDiffers: Bool {
        guard let t = track, primedRate == nil else { return false }
        return t.sampleRate != deviceRate
    }

    private var badge: String {
        if let primed = primedRate { return "Primed for \(Format.rate(primed)) kHz" }
        if isBitPerfect { return "Bit Perfect" }
        if track == nil { return "Waiting" }
        return rateDiffers ? "Resampled" : "Not Bit Perfect"
    }

    private var badgeColor: Color {
        if isBitPerfect && primedRate == nil { return Look.green }
        return rateDiffers ? Look.orange : .secondary
    }

    private func formatText(bits: Int, rate: Double) -> String {
        bits > 0 ? "\(bits)-bit · \(Format.rate(rate)) kHz" : "Lossy · \(Format.rate(rate)) kHz"
    }

    /// Two aligned rows, so each format stays on one line:
    /// Source File  24-bit · 88.2 kHz
    /// DAC          24-bit · 96 kHz   ⓘ
    private var pathRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Source File").foregroundStyle(.secondary)
                Text(track.map { formatText(bits: $0.bitDepth, rate: $0.sampleRate) } ?? "Nothing yet")
                    .lineLimit(1).textSelection(.enabled)
            }
            GridRow {
                Text("DAC").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(formatText(bits: deviceBits, rate: deviceRate))
                        .foregroundStyle(rateDiffers ? Look.orange : .primary)
                        .lineLimit(1).textSelection(.enabled)
                    InfoButton(text: pathExplanation)
                }
            }
        }
        .font(.callout.monospacedDigit())
    }

    private var pathExplanation: String {
        let name = deviceName ?? "This output"
        if let primed = primedRate {
            return "\(name) is primed for \(Format.rate(primed)) kHz. Start a \(Format.rate(primed)) kHz track and it plays with no rate switch. BitPolish follows the next track as usual once it starts."
        }
        guard let t = track else {
            return "Nothing has played yet. Once Music plays a track, this compares the file with what reaches the DAC."
        }
        let src = Format.rate(t.sampleRate), out = Format.rate(deviceRate)
        if rateDiffers {
            return "\(name) doesn't accept \(src) kHz, so macOS resamples the track to \(out) kHz before it leaves your Mac. Resampling recalculates every sample, so this track isn't bit-perfect, though it stays high resolution. An output that accepts \(src) kHz would carry it untouched."
        }
        if t.bitDepth == 0 {
            return "Same rate, so nothing is recalculated. This is a lossy file (AAC or MP3), which has no fixed bit depth: Music decodes it and the result passes to the DAC unchanged."
        }
        if t.bitDepth < deviceBits {
            return "Same rate, so nothing is recalculated. The \(t.bitDepth)-bit samples travel inside \(deviceBits)-bit words with zeros added below, so the DAC receives the music unchanged. This is still bit-perfect."
        }
        if t.bitDepth > deviceBits {
            if let top = topBitDepth, top > deviceBits {
                return "This is a \(t.bitDepth)-bit track and the bit depth is locked at \(deviceBits)-bit, so its lowest bits are cut. Choose \(top)-bit under Bit depth to carry it whole."
            }
            return "This is a \(t.bitDepth)-bit track and \(name) tops out at \(deviceBits)-bit, so its lowest bits are cut on this device."
        }
        return "The DAC receives the file's samples exactly as decoded: same rate, same bit depth, nothing recalculated."
    }
}

/// Always visible: Music's slider can't be checked without a permission
/// prompt, so this reminds. The system volume can be checked, so the line
/// turns orange when it's low.
struct VolumeReminder: View {
    let full: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(full
                 ? "Reminder: keep Music and system volume at 100% for bit-perfect playback. Set your listening level on the DAC."
                 : "System volume is below 100%, so playback isn't bit-perfect. Turn the DAC down, then raise the system volume all the way.")
                .font(.footnote)
                .foregroundStyle(full ? AnyShapeStyle(.secondary) : AnyShapeStyle(Look.orange))
                .fixedSize(horizontal: false, vertical: true)
            InfoButton(text: "Software volume works by recalculating every sample, so any setting below 100% changes the music before it leaves your Mac. At 100%, the samples pass through untouched. Leave macOS and Music all the way up and set your listening level on your DAC or amp instead. Turn the DAC down first, so the jump to 100% isn't loud.\n\nBitPolish can see the system volume and will warn you here if it drops. It can't see Music's own volume slider without asking for permission to control Music, so that one is up to you.")
        }
    }
}

// MARK: Bit depth

/// Plain text when the device tops out at 24-bit or less; otherwise the
/// number is a small pop-up offering 24-bit or the device's maximum.
struct BitDepthRow: View {
    let choices: [Int]
    let locked: Int
    let deviceName: String?
    /// For the pop-up's action only.
    let session: SessionController

    var body: some View {
        HStack(spacing: 6) {
            if choices.count > 1 {
                Text("Bit depth locked at")
                ChoicePopUp(titles: choices.map { "\($0)-bit" },
                            selected: choices.firstIndex(of: locked) ?? 0) {
                    session.setLockedBitDepth(choices[$0])
                }
                .fixedSize()
                .accessibilityLabel("Bit depth")
            } else {
                Text("Bit depth locked at \(locked)-bit")
            }
            InfoButton(text: explanation)
            Spacer()
        }
        .padding(Look.section)
    }

    /// Written for listeners who aren't audio engineers: what BitPolish
    /// does, then why, in plain cause-and-effect steps.
    private var explanation: String {
        let name = deviceName ?? "this device"
        let bits = locked
        let noSwitching = "Switching the bit depth from track to track would add risk without any benefit: a wrong guess could cut a 24-bit track down to 16 bits, and each switch could cause a click."
        let optical = "If you use an optical or coaxial cable: these connections (called S/PDIF) carry at most 24 bits, so a higher setting gains nothing over them. Many optical connections also top out at 96 or 192 kHz, and some optical cables don't carry 192 kHz reliably. Finding one that does can take a few tries, so if you hear dropouts at high sample rates, try a different cable."
        if bits > BitDepth.standard {
            return "BitPolish holds \(name) at \(bits)-bit, whatever each track's own bit depth happens to be, because you chose its highest setting.\n\n16-bit and 24-bit music travels inside the \(bits)-bit samples with zeros filled in below, so nothing about the music changes. If you don't have music mastered above 24-bit, the 24-bit setting works just as well.\n\n\(optical)"
        }
        if bits < BitDepth.standard {
            return "BitPolish holds \(name) at \(bits)-bit, the most it accepts, whatever each track's own bit depth happens to be.\n\nAs a result, 16-bit music reaches your DAC unchanged, but 24-bit tracks lose their lowest bits on this device. A DAC that accepts 24-bit would carry them unchanged.\n\n\(noSwitching)"
        }
        let higher = choices.count > 1
            ? " Only choose a higher setting if you have music mastered above 24-bit and your DAC is connected by USB and can use it." : ""
        return "BitPolish holds \(name) at 24-bit, whatever each track's own bit depth happens to be.\n\nThis is because 24-bit can carry both 16-bit and 24-bit music without changing a single sample. A 16-bit track simply travels with zeros filled in below its last bit, so what reaches your DAC is exactly what's in the file. As a result, there's no reason to switch bit depth from track to track. \(noSwitching)\n\nNearly all music is 16-bit or 24-bit, which is why 24-bit is the default.\(higher)\n\n\(optical)"
    }
}

// MARK: Manually Prime DAC

/// Thin buttons in two rows by rate family (44.1 kHz family over the
/// 48 kHz family), each rate in a fixed place. Rates the DAC doesn't
/// accept stay in place, faded and unclickable, so the gaps show.
struct PrimingSection: View {
    let rows: [PrimingRow]
    let deviceRate: Double
    let canPrime: Bool
    let isPlaying: Bool
    let deviceName: String?
    /// For the buttons' action only.
    let session: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SectionLabel("Manually Prime DAC")
                InfoButton(text: explanation)
                Spacer()
                if isPlaying {
                    Text("Pause Music to prime").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(rows) { row in
                    GridRow {
                        ForEach(row.cells, id: \.rate) { cell in
                            PrimeButton(rate: cell.rate,
                                        supported: cell.supported,
                                        current: deviceRate == cell.rate,
                                        enabled: canPrime) { session.prime(cell.rate) }
                                .help(cell.supported ? "" : "Not accepted; tracks at this rate play at \(Format.rate(cell.playsAt)) kHz, resampled")
                        }
                    }
                }
            }
        }
        .padding(Look.section)
    }

    private var explanation: String {
        let name = deviceName ?? "this device"
        // A DAC that takes every rate shown has no faded ones to look for.
        let rateNote = rows.allSatisfy { $0.cells.allSatisfy(\.supported) }
            ? "\(name) accepts every rate shown, so each track plays at its own rate."
            : "Faded rates are ones \(name) doesn't accept; tracks at those rates play at the next rate up, after macOS converts them."
        return "BitPolish changes your DAC's sample rate automatically to match each track. When two tracks in a row have different sample rates, this causes a short gap in the music while the DAC switches over.\n\nIf you know what you'll play next and its sample rate, you can avoid the gap: stop or pause Music, choose that sample rate here, then start the track. The DAC switches now, while nothing is playing, so the track begins right away. Once the next track starts, BitPolish goes back to following each track automatically.\n\nThe top row is the 44.1 kHz family of rates and the bottom row the 48 kHz family. \(rateNote)"
    }
}

// MARK: Playing file

struct FileSection: View {
    /// Nil for an Apple Music stream, which has no local file.
    let file: FileInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Playing File")
            if let f = file {
                // The title (or, without one, the file name) reveals the file
                // in Finder.
                HoverLink(label: f.title.map { [$0, f.artist].compactMap { $0 }.joined(separator: " · ") }
                              ?? f.url.lastPathComponent,
                          font: .callout.weight(.medium), primary: true) {
                    // Finder does the reveal; BitPolish opens nothing.
                    NSWorkspace.shared.activateFileViewerSelecting([f.url])
                }
                    .help("Show in Finder")
                    .accessibilityHint("Shows the file in Finder")
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    if let codec = f.codec {
                        specRow("Format", "\(codec) · \(f.container)")
                        if let ch = f.channels { specRow("Channels", ch == 2 ? "2 (stereo)" : "\(ch)") }
                    } else {
                        specRow("Format", "\(f.container) · not reported by Music")
                    }
                    if let kbps = f.bitRateKbps { specRow("Bit rate", "\(kbps.formatted()) kbps") }
                    if f.fileSize > 0 { specRow("Size", ByteCountFormatter.string(fromByteCount: f.fileSize, countStyle: .file)) }
                }
            } else {
                Text("Apple Music stream. There's no local file to read; the format above comes from Music's decoder.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Look.section)
    }

    private func specRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.callout.monospacedDigit())
    }
}

// MARK: Output

/// The Mac's sound output. While On, an AppKit pop-up of DACs, for moving
/// between them mid-session, that opens with the current one in place.
/// While Off, a pop-up that picks the DAC switching On will use (the Mac's
/// output doesn't change until then); with no DAC, the output's name.
struct OutputRow: View {
    let isOn: Bool
    let dacs: [SessionController.OutputChoice]
    /// While On, the device in use.
    let deviceID: AudioDeviceID?
    let deviceName: String?
    /// While Off, the DAC switching On will use.
    let target: SessionController.OutputChoice?
    let onChooseOutput: (SessionController.OutputChoice) -> Void
    /// For the Off pick's action only.
    let session: SessionController

    var body: some View {
        HStack {
            Text("DAC").foregroundStyle(.secondary)
            Spacer()
            if isOn {
                OutputPopUp(outputs: dacs, current: deviceID,
                            currentName: deviceName ?? "None", onPick: onChooseOutput)
                    .fixedSize()
            } else if let target {
                OutputPopUp(outputs: dacs, current: target.id,
                            currentName: target.name, onPick: { session.pickOnTarget($0) })
                    .fixedSize()
            } else {
                Text(deviceName ?? "None").font(.body.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(Look.section)
    }
}

// MARK: Accepts and Details (Option-click)

/// Which rates the output takes at each bit depth.
struct AcceptsBlock: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Accepts")
            ForEach(lines, id: \.self) { line in
                Text(line).font(.caption.monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Accepts list and the set-and-forget settings (and the Dock icon),
/// kept behind Option so the everyday panel stays simple. It observes the
/// session: shown only with Option, and its checkboxes read system state
/// (the login item, the Dock) that a session change is what refreshes.
struct DetailsSection: View {
    @ObservedObject var session: SessionController
    let acceptsLines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AcceptsBlock(lines: acceptsLines)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Open at login", isOn: Binding(get: { session.opensAtLogin },
                                                      set: { session.setOpensAtLogin($0) }))
                if session.loginItemNeedsApproval {
                    HoverLink(label: "Allow it in Login Items settings…", font: .caption) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                HStack(spacing: 6) {
                    Toggle("Keep Bit-Perfect Listening on", isOn: $session.keepOn)
                    InfoButton(text: "Turns Bit-Perfect Listening on whenever BitPolish opens, and again whenever your DAC reconnects (after unplugging it, or docking your Mac). For DACs that stay connected all day.")
                }
                Toggle("Show in Dock", isOn: Binding(get: { session.showsInDock },
                                                     set: { session.setShowsInDock($0) }))
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Look.section)
    }
}

// MARK: About and Quit

/// Quit as a menu-style row, with a small About link in the lower right.
/// Above it, when a daily check has found one, the available update.
struct PanelFooter: View {
    let availableVersion: String?
    let onQuit: () -> Void
    let onAbout: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let version = availableVersion {
                MenuRow(title: "Update available: version \(version)…") { Updates.shared.checkForUpdates() }
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 8) {
                MenuRow(title: "Quit BitPolish", action: onQuit)
                HoverLink(label: "About", font: .caption, action: onAbout)
                    .padding(.trailing, 8)
                    .accessibilityLabel("About BitPolish")
            }
        }
        .padding(.horizontal, Look.inset - 8)
        .padding(.vertical, 6)
    }
}
