import AppKit
import Combine
import CoreAudio
import Foundation
import ServiceManagement
import BitPolishCore

/// Device state that only the hardware queue reads or writes.
final class HardwareState: @unchecked Sendable {
    /// The device BitPolish is managing, with its restore point. Set only after
    /// the restore point has been saved to disk, and cleared before it is
    /// restored, so no device change can ever happen without one.
    var armed: (device: AudioDevice, snapshot: Snapshot)?
    /// True when BitPolish's last change to the armed device never confirmed
    /// (the device didn't report it in time). The restore then waits for the
    /// device to settle first, so a late-landing change can't slip in after.
    var unconfirmed = false
    /// Change listeners on the device currently shown in the menu bar.
    var stopObserving: (() -> Void)?
    var observedID: AudioDeviceID?
}

/// The Bit-Perfect Listening state machine.
///
/// Off: hands off. BitPolish changes no settings, but it does quietly keep
/// track of what Music is playing (track format and file details) from
/// Music's notifications, its log, and the open-file table. All read-only.
/// So switching On needs no lookups: the device gets a single change,
/// straight to the track's rate at the locked bit depth.
///
/// On: save the device's restore point first, then follow Music's rate with
/// the bit depth locked.
///
/// Every CoreAudio call on a device happens on the serial `hardware` queue.
/// The main thread only reads system-wide properties (the default output),
/// Music's process object, and cached values.
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var device: AudioDevice?
    @Published private(set) var deviceRate: Double = 0
    @Published private(set) var deviceBits: Int = 0
    /// False when the device's volume (often the macOS volume slider) is below full.
    @Published private(set) var deviceVolumeFull = true
    @Published private(set) var deviceIsFloat = false
    /// Device changes queued or under way; the asterisk and the drift check
    /// wait for them to land.
    @Published private(set) var changesInFlight = 0
    /// The bit depth the lock last set on the device (it can be below the
    /// chosen depth at rates where the device offers less).
    private var lockedFormatBits: Int?
    @Published private(set) var track: TrackFormat?
    @Published private(set) var isPlaying = false {
        didSet { if isPlaying && !oldValue { playbackStarted() } }
    }
    /// Set while the DAC is primed for the next track's rate (see `prime`).
    @Published private(set) var primedRate: Double?
    @Published private(set) var unsupportedNote: String?
    @Published private(set) var notice: String?
    /// What the notice reports and which device it's about, which decide
    /// when it goes away (see `post` and `panelWillOpen`).
    private var noticeKind = NoticeKind.action
    private var noticeSubject: String?
    private var noticePostedAt = Date.distantPast
    private var noticeShownAt: Date?
    @Published private(set) var file: FileInfo?
    /// True when the playing track has no local file (an Apple Music stream).
    @Published private(set) var isStream = false
    /// The output device's fixed facts, read once per device. Cached because a
    /// USB device that is reconfiguring makes reads wait, and the panel must
    /// never wait on hardware while it draws.
    @Published private(set) var caps: DeviceCaps?
    /// True when macOS won't let this account read Music's log (standard,
    /// non-admin accounts), so tracks' rates can't be followed.
    @Published private(set) var logUnavailable = false
    /// Every choosable output (the Output menu shows the DACs among them),
    /// refreshed when devices come and go.
    @Published private(set) var outputs: [OutputChoice] = []
    /// True while Bit-Perfect Listening moves from one DAC to another, so
    /// the panel stays expanded through the brief Off-then-On.
    @Published private(set) var movingOutput = false

    struct OutputChoice: Equatable {
        var id: AudioDeviceID
        var uid: String?
        var name: String
        var eligible: Bool
        /// Displays (HDMI, DisplayPort) count as DACs, but are a last resort
        /// when choosing where switching On sends the sound.
        var isDisplay: Bool
    }


    struct DeviceCaps: Equatable {
        var id: AudioDeviceID
        var uid: String?
        var name: String
        var rates: [Double]
        var maxBits: Int
        /// Every bit depth with the rates it's offered at, one line each
        /// ("24- and 32-bit at 44.1, 48, … kHz"); depths sharing rates share a line.
        var accepts: [String]
        /// Set when this output can't do bit-perfect playback (built-in,
        /// Bluetooth, AirPlay, virtual): a short label and a one-line reason.
        var ineligibleShort: String?
        var ineligibleReason: String?
    }

    nonisolated static func readCaps(_ d: AudioDevice) -> DeviceCaps {
        let why = d.ineligibility
        return DeviceCaps(id: d.id, uid: d.uid, name: d.name, rates: d.availableRates, maxBits: d.maxIntegerBitDepth,
                          accepts: acceptsLines(d), ineligibleShort: why?.short, ineligibleReason: why?.reason)
    }

    nonisolated private static func acceptsLines(_ d: AudioDevice) -> [String] {
        var byDepth: [String: Set<Double>] = [:]
        for r in d.availablePhysicalFormatRanges {
            let f = r.mFormat
            let key = "\(f.mBitsPerChannel)-bit" + (f.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? " float" : "")
            byDepth[key, default: []].insert(f.mSampleRate)
        }
        let order = byDepth.keys.sorted { (Int($0.prefix { $0.isNumber }) ?? 0, $0) < (Int($1.prefix { $0.isNumber }) ?? 0, $1) }
        var groups: [(depths: [String], rates: [Double])] = []
        for key in order {
            let rates = byDepth[key]!.sorted()
            if let i = groups.firstIndex(where: { $0.rates == rates }) { groups[i].depths.append(key) }
            else { groups.append((depths: [key], rates: rates)) }
        }
        return groups.map { "\(BitDepth.joinedLabel($0.depths)) at \($0.rates.map(Format.rate).joined(separator: ", ")) kHz" }
    }

    /// On is possible whenever there's a DAC to switch on with.
    var canActivate: Bool { caps != nil && onTarget != nil }

    /// The DAC picked in the Output menu while Off, this run (by UID). Only
    /// BitPolish's choice: the Mac's output doesn't change until On.
    @Published private var pickedUID: String?

    /// Where switching On sends the sound: the DAC picked while Off, else the
    /// Mac's output if it's a DAC, else the DAC last used with BitPolish,
    /// else the first dedicated DAC (USB, Thunderbolt…), a display's audio
    /// only if nothing else.
    var onTarget: OutputChoice? {
        let dacs = outputs.filter(\.eligible)
        if let p = pickedUID, let picked = dacs.first(where: { $0.uid == p }) { return picked }
        if let caps, caps.ineligibleReason == nil {
            return dacs.first { $0.id == caps.id }
                ?? OutputChoice(id: caps.id, uid: caps.uid, name: caps.name, eligible: true, isDisplay: false)
        }
        let last = UserDefaults.standard.string(forKey: Self.lastDACKey)
        return dacs.first { $0.uid != nil && $0.uid == last } ?? dacs.first { !$0.isDisplay } ?? dacs.first
    }

    /// The target's capabilities, for the Off panel's Accepts preview: the
    /// shown device's own when it's the target, else read separately.
    @Published private(set) var targetCaps: DeviceCaps?

    /// The Output menu while Off: choose the DAC switching On will use, and
    /// remember it. Changes nothing on the Mac.
    func pickOnTarget(_ choice: OutputChoice) {
        guard !isOn, choice.eligible else { return }
        pickedUID = choice.uid
        if let uid = choice.uid { UserDefaults.standard.set(uid, forKey: Self.lastDACKey) }
        refreshTargetCaps()
    }

    /// Keeps `targetCaps` in step with the target.
    private func refreshTargetCaps() {
        guard let target = onTarget else { targetCaps = nil; return }
        if let caps, caps.id == target.id { if targetCaps != caps { targetCaps = caps }; return }
        guard targetCaps?.id != target.id else { return }
        hardware.async { [weak self] in
            let read = Self.readCaps(AudioDevice(id: target.id))
            DispatchQueue.main.async {
                guard let self, self.onTarget?.id == target.id else { return }
                self.targetCaps = read
            }
        }
    }

    nonisolated private static let lastDACKey = "LastDAC"

    /// After a session that BitPolish started from a non-DAC output (the
    /// speakers, Bluetooth, AirPlay): the output to offer a return to. Off
    /// never moves sound there by itself, so nothing suddenly plays out loud.
    var returnOffer: (from: String, to: String)? {
        guard !isOn, let r = outputRevert, !r.originalIsDAC else { return nil }
        return (outputs.first { $0.id == r.setByUs.id }?.name ?? "the DAC", r.name)
    }

    private let music = MusicWatcher()
    private let fileQueue = DispatchQueue(label: "BitPolish.file", qos: .userInitiated)

    /// All device work, serialized. Restore points are always saved before the
    /// first change and restored after the last.
    private let hardware = DispatchQueue(label: "BitPolish.hardware", qos: .userInitiated)
    private let hw = HardwareState()
    /// Bumped on every flip, so results from a superseded flip are ignored.
    private var generation = 0
    private var lastReassert = Date.distantPast
    /// Bumped whenever priming is set, cleared, or superseded by a new track,
    /// so a pending "resumed without a new track" check can tell it's stale.
    private var primeToken = 0
    /// True once a track has started since the DAC was primed: the 1.5 s
    /// "resumed the same track" rule then no longer applies (a track that
    /// logs no format line, such as a WAV, keeps the primed rate).
    private var trackChangedSincePrime = false
    /// Set once BitPolish has moved the Mac's output during a session: the
    /// output from before, and the one BitPolish set. Off (or quit) puts a
    /// DAC original back if the output is still the one BitPolish set; a
    /// non-DAC original (the speakers) waits for a click on Return.
    private var outputRevert: OutputRevert?

    struct OutputRevert {
        var original: AudioDevice
        var name: String
        var originalIsDAC: Bool
        var setByUs: AudioDevice
    }
    /// Backoff for retrying a restore that failed (e.g. another app holding
    /// the DAC exclusively) while the DAC stays connected.
    private var restoreRetryDelay: TimeInterval = 2
    private var restoreRetryScheduled = false

    init() {
        music.onFormat = { [weak self] in self?.follow($0) }
        music.onPlayerState = { [weak self] playing in
            // Music sends this on every track change too; only a real
            // change redraws.
            if self?.isPlaying != playing { self?.isPlaying = playing }
            self?.watchMusicOutput()   // attach if Music started after BitPolish
        }
        music.onTrackChange = { [weak self] info in
            self?.primeToken += 1   // a new track: its own format settles the priming
            self?.trackChangedSincePrime = true
            self?.loadFileInfo(info: info)
        }
        music.onLogDenied = { [weak self] in self?.logUnavailable = true }
        music.onRecoveredTitle = { [weak self] title in
            // Only if no notification has said what's playing yet.
            guard let self, self.nowPlaying.title == nil else { return }
            Trace.log("recovered playing title from Music's log: \(title)")
            self.nowPlaying.title = title
            self.loadFileInfo(info: [:])
        }
        device = AudioDevice.defaultOutput()
        // Restore points left behind (crash, force quit, or a DAC unplugged
        // while On) are put back first, for every device that's connected.
        hardware.async { [weak self] in
            let report = Self.restorePending(excluding: nil)
            DispatchQueue.main.async { self?.show(report, .launch) }
        }
        refreshDeviceState()
        refreshOutputs()
        // Follow the system output: a device chosen in Sound settings, or one
        // plugged in or unplugged.
        AudioDevice.observeSystemOutputChanges { [weak self] in
            Task { @MainActor in self?.outputsChanged() }
        }
        observeWorkspace()
        // Read-only watching starts now, so the state is known before On.
        music.start()
        watchMusicOutput()
        loadFileInfo(info: [:])
    }

    // MARK: Music and the Mac

    private var musicOutputObject: AudioObjectID?
    private var stopObservingMusicOutput: (() -> Void)?

    /// Music's notifications only say "playing" when something changes, so
    /// after launching mid-track BitPolish would think Music is idle. CoreAudio
    /// knows whether Music's process is sending audio right now; read that,
    /// and listen for changes. These are process objects, not devices, so they
    /// don't wait on hardware. No permission is involved.
    private func watchMusicOutput() {
        guard let pid = MusicApp.pid, let object = AudioDevice.processObject(pid: pid),
              object != musicOutputObject else { return }
        stopObservingMusicOutput?()
        musicOutputObject = object
        isPlaying = AudioDevice.isRunningOutput(processObject: object)
        stopObservingMusicOutput = AudioDevice.observeRunningOutput(processObject: object) { [weak self] in
            Task { @MainActor in
                guard let self, let o = self.musicOutputObject else { return }
                let running = AudioDevice.isRunningOutput(processObject: o)
                if running != self.isPlaying { self.isPlaying = running }
            }
        }
    }

    /// Music launching or quitting (including a crash, which sends no
    /// "Stopped" notification), and the Mac waking from sleep.
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == MusicApp.bundleID else { return }
            MainActor.assumeIsolated { self?.musicQuit() }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == MusicApp.bundleID else { return }
            MainActor.assumeIsolated { self?.watchMusicOutput() }
        }
        // Some DACs come back from sleep at a default format; put the lock back.
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.lastReassert = .distantPast
                self?.refreshDeviceState()
            }
        }
    }

    private func musicQuit() {
        stopObservingMusicOutput?()
        stopObservingMusicOutput = nil
        musicOutputObject = nil
        isPlaying = false
        clearPriming()
        music.musicQuit()
        clearFile()
    }

    private func clearFile() {
        playingFile = nil
        isStream = false
        file = nil
    }

    // MARK: Restore points

    struct RestoreReport {
        var restored: [String] = []
        var missing: [String] = []
        var failed: [String] = []

        mutating func add(_ name: String, _ result: Snapshot.RestoreResult) {
            switch result {
            case .restored: restored.append(name)
            case .deviceMissing: missing.append(name)
            case .failed: failed.append(name)   // its file is kept; retried later
            }
        }
    }

    /// Why a restore ran, which decides what (if anything) to tell the user.
    enum RestoreContext { case launch, reconnect, switchOff }

    /// Restores every pending restore point whose device is connected, except
    /// the one BitPolish is managing right now. Hardware queue only.
    nonisolated private static func restorePending(excluding uid: String?, attempts: Int = 3) -> RestoreReport {
        var report = RestoreReport()
        for snap in Snapshot.loadAll() where snap.deviceUID != uid {
            let result = snap.restore(attempts: attempts)
            if result == .restored { Snapshot.delete(uid: snap.deviceUID) }
            report.add(snap.deviceName, result)
        }
        return report
    }

    /// Disarms and restores the managed device. The file is the source of
    /// truth; the in-memory copy covers a file that can't be read back.
    /// Hardware queue only.
    nonisolated private static func restoreArmed(_ state: HardwareState, attempts: Int = 3) -> RestoreReport {
        var report = RestoreReport()
        guard let armed = state.armed else { return report }
        state.armed = nil   // disarm before restoring: no further changes
        let snap = Snapshot.load(uid: armed.snapshot.deviceUID) ?? armed.snapshot
        let result = snap.restore(settleFirst: state.unconfirmed, attempts: attempts)
        if result == .restored { Snapshot.delete(uid: snap.deviceUID) }
        report.add(snap.deviceName, result)
        state.unconfirmed = false
        return report
    }

    private func show(_ report: RestoreReport, _ context: RestoreContext) {
        if !report.failed.isEmpty { scheduleRestoreRetry() }
        if let name = report.failed.first {
            post("Couldn't put \(name) back to its earlier settings yet. BitPolish will try again.", .pending, about: name)
        } else if let name = report.missing.first, context != .reconnect {
            post("\(name) isn't connected. Its settings will be restored the next time it is.", .pending, about: name)
        } else if let name = report.restored.first, context == .launch {
            post("Restored \(name) to its settings from before BitPolish's last session ended unexpectedly.", .event, about: name)
        } else if let name = report.restored.first, context == .reconnect {
            post("\(name) is back and has been restored to its settings from before Bit-Perfect Listening.", .event, about: name)
        }
    }

    /// Retries failed restores with a growing delay (2 s up to 60 s) until
    /// they succeed or the device disconnects (then the reconnect restores
    /// it). The notice promises a retry; this keeps the promise.
    private func scheduleRestoreRetry() {
        guard !restoreRetryScheduled else { return }
        restoreRetryScheduled = true
        let delay = restoreRetryDelay
        restoreRetryDelay = min(delay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.restoreRetryScheduled = false
            self.hardware.async { [weak self, hw] in
                let report = Self.restorePending(excluding: hw.armed?.snapshot.deviceUID, attempts: 1)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if report.failed.isEmpty {
                        self.restoreRetryDelay = 2
                        if let name = report.restored.first {
                            self.post("\(name) is back to its settings from before Bit-Perfect Listening.", .event, about: name)
                        }
                        self.refreshDeviceState()
                    } else {
                        self.scheduleRestoreRetry()
                    }
                }
            }
        }
    }

    // MARK: Output changes

    /// The default output changed, or a device was plugged in or unplugged.
    private func outputsChanged() {
        let defaultNow = AudioDevice.defaultOutput()
        // Changed elsewhere (Sound settings, Control Center): the user's own
        // choice now, so there's nothing for Off to put back.
        if let r = outputRevert, let now = defaultNow, now != r.setByUs, !movingOutput { outputRevert = nil }
        let managed = isOn ? device : nil
        hardware.async { [weak self, hw] in
            // A device with a pending restore point may have come back.
            let report = Self.restorePending(excluding: hw.armed?.snapshot.deviceUID)
            let managedAlive = managed?.isAlive ?? true
            DispatchQueue.main.async {
                guard let self else { return }
                self.show(report, .reconnect)
                if self.isOn, let managed, managed == self.device {
                    let name = self.caps?.name ?? "The DAC"
                    if !managedAlive {
                        self.switchOff { [weak self] in
                            self?.post("\(name) was disconnected, so Bit-Perfect Listening switched off. Its settings will be restored when it's reconnected.", .pending, about: name)
                        }
                        return
                    }
                    if defaultNow != managed {
                        self.switchOff { [weak self] in
                            self?.post("The Mac's output changed away from \(name), so Bit-Perfect Listening switched off and put \(name) back as it was.", .event, about: name)
                        }
                        return
                    }
                }
                self.refreshDeviceState()
            }
        }
        refreshOutputs()
    }

    // MARK: Output menu

    /// Re-reads the choosable outputs in the background.
    private func refreshOutputs() {
        hardware.async { [weak self] in
            let list = AudioDevice.choosableOutputs().map {
                OutputChoice(id: $0.id, uid: $0.uid, name: $0.name, eligible: $0.ineligibility == nil,
                             isDisplay: [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort].contains($0.transportType))
            }
            DispatchQueue.main.async {
                guard let self, self.outputs != list else { return }
                let before = Set(self.outputs.filter(\.eligible).map(\.id))
                let firstLoad = self.outputs.isEmpty
                self.outputs = list
                self.refreshTargetCaps()
                // A DAC appeared (replugged, or the Mac docked): with Keep On,
                // switch back on once it has settled.
                // Only a dedicated DAC counts (a monitor's audio waking up
                // doesn't), preferably the one last used with BitPolish.
                let newDACs = list.filter { $0.eligible && !$0.isDisplay && !before.contains($0.id) }
                let last = UserDefaults.standard.string(forKey: Self.lastDACKey)
                let appeared = last == nil ? !newDACs.isEmpty : newDACs.contains { $0.uid == last }
                if appeared, !firstLoad, self.keepOn, !self.isOn {
                    Trace.log("DAC connected: Keep On will switch on")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.refreshDeviceState()
                        self?.keepOnIfSet()
                    }
                }
            }
        }
    }

    /// Moves Bit-Perfect Listening to another DAC while On: the old one is
    /// put back first, then the output changes and the new one is locked.
    func chooseOutput(_ choice: OutputChoice, completion: (() -> Void)? = nil) {
        guard isOn, choice.eligible, !movingOutput,
              let target = outputs.first(where: { $0.id == choice.id }).map({ AudioDevice(id: $0.id) }),
              target != device else { completion?(); return }
        movingOutput = true
        // Remember what to put back at Off. Recorded before the change, so
        // the change notification doesn't read it as someone else's.
        let created = outputRevert == nil
        if var r = outputRevert {
            r.setByUs = target
            outputRevert = target == r.original ? nil : r
        } else if let before = device {
            let name = outputs.first { $0.id == before.id }?.name ?? "the previous DAC"
            outputRevert = OutputRevert(original: before, name: name, originalIsDAC: true, setByUs: target)
        }
        switchOff { [weak self] in
            guard let self else { return }
            self.hardware.async { [weak self] in
                let ok = AudioDevice.setDefaultOutput(target)
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard ok else {
                        self.post("Couldn't switch the Mac's output to \(choice.name).", .action)
                        if created { self.outputRevert = nil }
                        self.movingOutput = false
                        self.refreshDeviceState()
                        completion?()
                        return
                    }
                    // The pick is now the target, as a pick while Off is, so
                    // switchOn locks it where the sound already is. Without
                    // this, onTarget still named the old DAC (caps are re-read
                    // in the background) and the sound went straight back.
                    self.pickedUID = choice.uid
                    self.refreshDeviceState()
                    self.switchOn { [weak self] in
                        self?.movingOutput = false
                        completion?()
                    }
                }
            }
        }
    }

    // MARK: On / Off

    /// Flips Bit-Perfect Listening. `isOn` changes immediately (for the UI);
    /// the device work runs in the background and `completion` fires on the
    /// main thread once it's done.
    func setOn(_ on: Bool, completion: (() -> Void)? = nil) {
        on ? switchOn(completion: completion) : switchOff(revertingOutput: true, completion: completion)
    }

    /// `keepNotice`: leave a shown notice (e.g. a crash-restore report) in
    /// place, for Keep On switching on by itself.
    private func switchOn(keepNotice: Bool = false, completion: (() -> Void)?) {
        guard !isOn, let current = AudioDevice.defaultOutput() else {
            if !isOn { post("No output device found.", .action) }
            completion?()
            return
        }
        // The target isn't the Mac's output (the speakers, or another DAC
        // picked while Off): move the sound there first, recorded so Off can
        // go back to a DAC or offer Return to anything else. No DAC: stop.
        // Before the outputs and capabilities have been read (just after
        // launch), use the current output; arming checks it's a DAC.
        guard let chosen = onTarget ?? (caps == nil ? OutputChoice(id: current.id, uid: current.uid, name: current.name,
                                                                    eligible: true, isDisplay: false) : nil) else {
            completion?(); return
        }
        var target = current
        var moveSound = false
        if chosen.id != current.id {
            target = AudioDevice(id: chosen.id)
            moveSound = true
            if outputRevert == nil {
                let currentIsDAC = caps?.id == current.id ? caps?.ineligibleReason == nil
                                                          : outputs.first { $0.id == current.id }?.eligible ?? false
                let name = caps?.id == current.id ? caps?.name : outputs.first { $0.id == current.id }?.name
                outputRevert = OutputRevert(original: current, name: name ?? "the previous output",
                                            originalIsDAC: currentIsDAC, setByUs: target)
            }
        }
        let device = target
        generation += 1
        let gen = generation
        self.device = device
        if !keepNotice { notice = nil }
        clearPriming()
        isOn = true
        changesInFlight += 1
        let trackRate = track?.sampleRate
        hardware.async { [weak self, hw] in
            if moveSound && !AudioDevice.setDefaultOutput(device) {
                DispatchQueue.main.async {
                    guard let self else { return }
                    if gen == self.generation { self.isOn = false; self.post("Couldn't switch the sound to the DAC, so nothing was changed.", .action) }
                    self.outputRevert = nil
                    self.changesInFlight -= 1
                    self.refreshDeviceState()
                    completion?()
                }
                return
            }
            let caps = Self.readCaps(device)   // fresh, on this queue
            let failure = Self.arm(device, caps: caps, trackRate: trackRate, state: hw)
            if failure == nil, let uid = caps.uid { UserDefaults.standard.set(uid, forKey: Self.lastDACKey) }
            let rate = device.nominalRate, bits = device.bitDepth
            DispatchQueue.main.async {
                guard let self else { return }
                if self.device == device {
                    self.caps = caps
                    self.deviceRate = rate
                    self.deviceBits = bits
                    self.lockedFormatBits = bits
                }
                if gen == self.generation, let failure {
                    self.isOn = false
                    self.post(failure, .action)
                    // The session didn't start: a move away from another DAC
                    // is undone (a speakers original keeps its Return).
                    if let r = self.outputRevert, r.originalIsDAC {
                        self.outputRevert = nil
                        self.hardware.async { _ = Self.revertOutput(r) }
                    }
                }
                self.changesInFlight -= 1
                self.refreshDeviceState()
                completion?()
            }
        }
    }

    /// Saves the device's restore point, arms it, and makes the one change.
    /// Returns a message if anything stopped it (nothing changed then).
    /// Hardware queue only.
    nonisolated private static func arm(_ device: AudioDevice, caps: DeviceCaps, trackRate: Double?,
                                        state: HardwareState) -> String? {
        if let reason = caps.ineligibleReason { return reason }
        guard let uid = device.uid else { return "Couldn't identify \(caps.name), so nothing was changed." }
        // An earlier restore point for this device (crash, or unplugged while
        // On) goes back first, so it's never captured over.
        if let pending = Snapshot.load(uid: uid) {
            guard pending.restore() == .restored else {
                return "Couldn't put \(caps.name) back to its earlier settings, so nothing was changed. Try again in a moment."
            }
            Snapshot.delete(uid: uid)
        }
        guard let snap = Snapshot.capture(device) else {
            return "Couldn't read \(caps.name)'s settings, so nothing was changed."
        }
        do {
            try snap.save()
        } catch {
            return "Couldn't save the restore point, so nothing was changed. (\(error.localizedDescription))"
        }
        state.armed = (device, snap)
        state.unconfirmed = false
        apply(rate: TrackFormat.outputRate(for: trackRate, supported: caps.rates, current: snap.nominalRate),
              bits: lockedBits(caps), to: device, state: state)
        return nil
    }

    /// `revertingOutput`: the user switched Off, so BitPolish's own output
    /// change is undone too (not for the automatic Offs, or the Off inside a
    /// move between DACs).
    private func switchOff(revertingOutput: Bool = false, completion: (() -> Void)?) {
        guard isOn else { completion?(); return }
        generation += 1
        isOn = false
        clearPriming()
        let revert = revertingOutput && outputRevert?.originalIsDAC == true ? outputRevert : nil
        hardware.async { [weak self, hw] in
            let report = Self.restoreArmed(hw)
            let reverted = revert.map(Self.revertOutput) ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                if let revert {
                    // The session is over either way (the DAC may be gone).
                    self.outputRevert = nil
                    if reverted { self.post("The Mac's output is back to \(revert.name).", .event, about: revert.name) }
                }
                self.show(report, .switchOff)
                self.refreshDeviceState()
                self.updateUnsupportedNote()
                completion?()
            }
        }
    }

    /// Called on quit. Waits for any queued device work, then restores every
    /// connected device that has a restore point, whatever the switch shows.
    /// One attempt each, so quitting can't hang on a device that refuses;
    /// anything not restored keeps its file and is retried at next launch.
    /// (Change listeners are left alone: removing them while the main thread
    /// waits here could stall, and the process is exiting anyway.)
    func shutdown() {
        let wasOn = isOn
        isOn = false
        // Only a running session's DAC move is undone; never to the speakers.
        let revert = wasOn && outputRevert?.originalIsDAC == true ? outputRevert : nil
        hardware.sync { [hw] in
            _ = Self.restoreArmed(hw, attempts: 1)
            _ = Self.restorePending(excluding: nil, attempts: 1)
            if let revert { _ = Self.revertOutput(revert) }
        }
        music.stop()
    }

    /// Puts the Mac's output back to `revert.original` if it's still the one
    /// BitPolish set and the original is connected. Hardware queue only.
    nonisolated private static func revertOutput(_ revert: OutputRevert) -> Bool {
        guard AudioDevice.defaultOutput() == revert.setByUs, revert.original.isAlive else { return false }
        return AudioDevice.setDefaultOutput(revert.original)
    }

    /// The Return button after a session that started on the speakers (or
    /// another non-DAC output): puts the sound back there, on request.
    func returnToOriginalOutput() {
        guard let revert = outputRevert, !isOn else { return }
        hardware.async { [weak self] in
            let ok = Self.revertOutput(revert)
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputRevert = nil
                if !ok { self.post("Couldn't switch the sound back to \(revert.name).", .action) }
                self.refreshDeviceState()
            }
        }
    }

    // MARK: Keep Bit-Perfect Listening on

    private static let keepOnKey = "KeepOn"

    /// For setups whose DAC stays connected: switch on at every launch and
    /// whenever a DAC reconnects.
    var keepOn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.keepOnKey) }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: Self.keepOnKey) }
    }

    /// If Keep On is set: switch on as a click would, once the outputs and
    /// the current device are known (up to 5 s). With no DAC to use, stay
    /// off quietly.
    func keepOnIfSet(attempt: Int = 0) {
        guard keepOn, !isOn else { return }
        guard caps != nil, !outputs.isEmpty else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.keepOnIfSet(attempt: attempt + 1)
                }
            }
            return
        }
        guard canActivate else { return }
        // Never onto a display's audio by itself.
        let armID = onTarget?.id
        if outputs.first(where: { $0.id == armID })?.isDisplay == true { return }
        Trace.log("Keep On: switching on")
        switchOn(keepNotice: true, completion: nil)
    }

    #if BITPOLISH_TESTING
    /// Testing only: act as if Music started a track at `rate`.
    func simulateTrackForTesting(_ rate: Double) { follow(TrackFormat(sampleRate: rate, bitDepth: 24)) }
    /// Testing only: moves the notices' clock forward.
    var clockOffsetForTesting: TimeInterval = 0
    /// Testing only: shows a notice as if BitPolish had posted it.
    func postNoticeForTesting(_ text: String, _ kind: NoticeKind, about subject: String? = nil) { post(text, kind, about: subject) }
    /// Testing only: act as if the DACs were unplugged and plugged back in.
    func simulateDACReconnectForTesting() {
        outputs.removeAll(where: \.eligible)
        refreshOutputs()
    }
    #endif

    // MARK: Open at login

    /// Apple's login-item mechanism; the item shows in System Settings ›
    /// General › Login Items. Only ever set by the user's checkbox.
    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    var loginItemNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Show in Dock (see Dock.swift); here so the Details checkbox refreshes.
    var showsInDock: Bool { Dock.isShown }

    func setShowsInDock(_ shown: Bool) {
        objectWillChange.send()
        Dock.setShown(shown)
    }

    func setOpensAtLogin(_ on: Bool) {
        objectWillChange.send()
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            post(on ? "Couldn't add BitPolish to your login items." : "Couldn't remove BitPolish from your login items.", .action)
        }
    }

    /// Clears a shown notice (before measuring the panel for a flip).
    func clearNotice() { notice = nil }

    /// Shows a notice of the given kind, about the named device if it
    /// concerns one.
    private func post(_ text: String, _ kind: NoticeKind, about subject: String? = nil) {
        notice = text
        noticeKind = kind
        noticeSubject = subject
        noticePostedAt = now
        noticeShownAt = nil
    }

    /// The panel is opening: drop a notice that has run its course (spec,
    /// Notices), and start an event notice's clock the first time it's shown.
    func panelWillOpen() {
        guard notice != nil else { return }
        let otherDAC = noticeSubject.map { subject in
            caps.map { $0.ineligibleReason == nil && $0.name != subject } ?? false
        } ?? false
        if NoticePolicy.expired(kind: noticeKind, postedAt: noticePostedAt, firstShownAt: noticeShownAt,
                                now: now, otherDACInUse: otherDAC) {
            notice = nil
        } else if noticeShownAt == nil {
            noticeShownAt = now
        }
    }

    private var now: Date {
        #if BITPOLISH_TESTING
        return Date().addingTimeInterval(clockOffsetForTesting)
        #else
        return Date()
        #endif
    }

    // MARK: Following the source

    /// Records the track's format; touches the device only while On.
    private func follow(_ format: TrackFormat) {
        track = format
        clearPriming()   // the track is known now, so follow it
        updateUnsupportedNote()
        // A newly known format updates the file details, and can settle
        // which open file is playing if that was still unknown.
        if playingFile == nil && !isStream { loadFileInfo(info: [:]) } else { rebuildFileInfo() }
        // Until caps describe this device (right after switching On), the
        // drift check applies the track's rate once they do.
        guard isOn, let device, caps?.id == device.id else { return }
        applyLock(rate: targetRate(for: format), to: device)
    }

    private func targetRate(for format: TrackFormat?) -> Double {
        TrackFormat.outputRate(for: format?.sampleRate, supported: caps?.rates ?? [], current: deviceRate)
    }

    /// The rate BitPolish holds the device at: the primed rate while primed,
    /// otherwise the track's.
    private var desiredRate: Double { primedRate ?? targetRate(for: track) }

    // MARK: Manually Prime DAC

    /// True when the Prime buttons work: On, and Music paused or stopped.
    var canPrime: Bool { isOn && !isPlaying && caps?.ineligibleReason == nil }

    /// Sets the DAC to the next track's rate while Music is stopped, so it
    /// relocks in silence and the track starts with no rate switch. Lasts
    /// until the next track's format is known.
    func prime(_ rate: Double) {
        guard canPrime, let device, caps?.id == device.id, caps?.rates.contains(rate) == true else { return }
        Trace.log("priming \(Format.rate(rate)) kHz")
        primedRate = rate
        primeToken += 1
        trackChangedSincePrime = false
        // A format Music decoded before the pause is about some other track.
        music.discardHeld()
        applyLock(rate: rate, to: device)
    }

    private func clearPriming() {
        guard primedRate != nil else { return }
        Trace.log("priming cleared")
        primedRate = nil
        primeToken += 1
    }

    /// Music started playing while primed. A new track settles the priming
    /// itself (its format arrives with it); if none does within 1.5 s, the
    /// paused track was resumed, so it goes back to its own rate.
    private func playbackStarted() {
        guard primedRate != nil else { return }
        let token = primeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.primeToken == token, self.primedRate != nil,
                  !self.trackChangedSincePrime else { return }
            Trace.log("resumed without a new track: priming cleared")
            self.clearPriming()
            guard self.isOn, let device = self.device, self.caps?.id == device.id else { return }
            self.applyLock(rate: self.targetRate(for: self.track), to: device)
        }
    }

    private func updateUnsupportedNote() {
        guard let track, let caps else { unsupportedNote = nil; return }
        let target = targetRate(for: track)
        unsupportedNote = target == track.sampleRate ? nil
            : "\(caps.name) can't play \(Format.rate(track.sampleRate)) kHz. macOS is resampling to \(Format.rate(target)) kHz."
    }

    /// Sets the device to `rate` at the locked bit depth (the deepest integer
    /// format at or below `bits`; the physical format sets both). Hardware
    /// queue only, and only for the armed device: no restore point, no
    /// change. Idempotent.
    nonisolated private static func apply(rate: Double, bits: Int, to device: AudioDevice, state: HardwareState) {
        guard let armed = state.armed, armed.device == device else { return }
        // Wait for each change to land, so the next queued step (a restore,
        // another change) never starts from a stale read.
        var confirmed = true
        if let format = device.integerFormat(at: rate, maxBits: bits) {
            if device.physicalFormat != format { confirmed = device.setPhysicalFormatAndWait(format) }
        } else if device.nominalRate != rate {
            confirmed = device.setNominalRateAndWait(rate)
        }
        if !confirmed { state.unconfirmed = true }
    }

    /// While On, if the device has drifted from the lock (another app changed
    /// it, or it reset itself on wake), put the lock back. At most every 2 s,
    /// so a device that refuses can't cause a loop.
    private func reassertIfDrifted() {
        guard isOn, let device, let caps, caps.id == device.id else { return }
        let target = desiredRate
        // Compared with the depth the lock last set (a device may offer less
        // than the chosen depth at some rates), and never floating point.
        let expectedBits = lockedFormatBits ?? lockedBitDepth
        guard changesInFlight == 0, deviceRate != target || deviceBits != expectedBits || deviceIsFloat,
              Date().timeIntervalSince(lastReassert) > 2 else { return }
        lastReassert = Date()
        Trace.log("re-asserting lock: device \(deviceBits)/\(Format.rate(deviceRate)), target \(Format.rate(target))")
        applyLock(rate: target, to: device)
    }

    /// Locks `device` at `rate` and the locked bit depth on the hardware
    /// queue, then publishes what it reads back. While a change is in flight
    /// the menu bar's asterisk waits (the device's values are stale until
    /// the change lands).
    private func applyLock(rate: Double, bits: Int? = nil, to device: AudioDevice) {
        let bits = bits ?? lockedBitDepth
        changesInFlight += 1
        hardware.async { [weak self, hw] in
            Self.apply(rate: rate, bits: bits, to: device, state: hw)
            let readRate = device.nominalRate, readBits = device.bitDepth
            DispatchQueue.main.async {
                guard let self else { return }
                if self.device == device {
                    self.deviceRate = readRate
                    self.deviceBits = readBits
                    self.lockedFormatBits = readBits
                }
                self.changesInFlight -= 1
            }
        }
    }

    /// Re-reads the shown device's rate, bit depth and volume in the
    /// background (queued behind any device write), keeps a change listener on
    /// it, and publishes the results if that device is still the one shown.
    func refreshDeviceState() {
        let d = isOn ? device : AudioDevice.defaultOutput()
        device = d
        guard let d else { deviceRate = 0; deviceBits = 0; caps = nil; return }
        let needCaps = caps?.id != d.id
        hardware.async { [weak self, hw] in
            if hw.observedID != d.id {
                hw.stopObserving?()
                hw.stopObserving = d.observeFormatChanges { [weak self] in
                    Task { @MainActor in self?.refreshDeviceState() }
                }
                hw.observedID = d.id
            }
            let rate = d.nominalRate
            let bits = d.bitDepth
            let isFloat = d.isFloat
            let volumeFull = d.volumeIsFull
            let newCaps = needCaps ? Self.readCaps(d) : nil
            DispatchQueue.main.async {
                guard let self, self.device == d else { return }
                if let newCaps { self.caps = newCaps; self.updateUnsupportedNote() }
                if self.deviceRate != rate { self.deviceRate = rate }
                if self.deviceBits != bits { self.deviceBits = bits }
                if self.deviceIsFloat != isFloat { self.deviceIsFloat = isFloat }
                if self.deviceVolumeFull != volumeFull { self.deviceVolumeFull = volumeFull }
                self.reassertIfDrifted()
                self.refreshTargetCaps()
            }
        }
    }

    // MARK: Bit depth

    /// The bit depth the output is held at: the choice saved for this device,
    /// else 24 (or the device's maximum, if lower).
    var lockedBitDepth: Int { caps.map(Self.lockedBits) ?? 0 }

    /// The choices offered for this device: [24, its maximum] when it goes
    /// higher, otherwise just its maximum (then the panel shows plain text).
    var bitDepthChoices: [Int] { caps.map { BitDepth.choices(deviceMax: $0.maxBits) } ?? [] }

    nonisolated private static func bitDepthKey(_ uid: String) -> String { "LockedBitDepth.\(uid)" }

    /// Thread-safe (UserDefaults), so the hardware queue can use it too.
    nonisolated static func lockedBits(_ caps: DeviceCaps) -> Int {
        let stored = caps.uid.flatMap { UserDefaults.standard.object(forKey: bitDepthKey($0)) as? Int }
        return BitDepth.resolve(stored: stored, deviceMax: caps.maxBits)
    }

    /// Saves a new bit depth for this device; while On, applies it at once.
    func setLockedBitDepth(_ bits: Int) {
        guard let caps, let uid = caps.uid, bitDepthChoices.contains(bits), bits != lockedBitDepth else { return }
        objectWillChange.send()
        UserDefaults.standard.set(bits, forKey: Self.bitDepthKey(uid))
        Trace.log("bit depth set to \(bits)")
        guard isOn, let device, device.id == caps.id else { return }
        applyLock(rate: desiredRate, bits: bits, to: device)
    }

    /// The status line shown while the card unrolls, naming the change being made.
    var settingUpText: String {
        guard let caps else { return "Setting up…" }
        if let device, caps.id != device.id {
            return "Switching sound to \(outputs.first { $0.id == device.id }?.name ?? "the DAC")…"
        }
        return "Setting \(caps.name) to \(lockedBitDepth)-bit / \(Format.rate(targetRate(for: track))) kHz…"
    }

    /// While On, playback isn't bit-perfect (volume below 100%, resampled,
    /// or bits cut): the menu bar marks the rate with an asterisk. Not while
    /// primed, when the DAC is deliberately at another rate, nor while a
    /// change is still landing. Low volume counts even before a track is
    /// known.
    var notBitPerfect: Bool {
        guard isOn, primedRate == nil, changesInFlight == 0 else { return false }
        return !deviceVolumeFull || (track != nil && !isBitPerfect)
    }

    /// True when what reaches the device matches the track: rate equal, depth
    /// at least the track's, device volume full. (Music's own slider can't be
    /// read without a permission prompt, so it isn't part of this.)
    var isBitPerfect: Bool {
        guard isOn, let track else { return false }
        return deviceRate == track.sampleRate && deviceBits >= track.bitDepth && deviceVolumeFull
    }

    // MARK: The playing file

    /// What Music's last track notification said; nil until the first one.
    private var nowPlaying: (title: String?, artist: String?, durationMs: Int?) = (nil, nil, nil)
    private var playingFile: OpenFile?

    /// Finds the playing file without opening it (see FileInfo). The file
    /// path comes from Music's notification when it includes one, otherwise
    /// from the files Music has open. Streams have no file.
    private func loadFileInfo(info: [AnyHashable: Any]) {
        if !info.isEmpty {
            let ms = (info["Total Time"] as? NSNumber)?.intValue
            nowPlaying = (info["Name"] as? String, info["Artist"] as? String, ms)
        }
        let title = nowPlaying.title
        let location = (info["Location"] as? String).flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        guard let pid = MusicApp.pid else { clearFile(); return }
        // Give Music a moment to open the new file after announcing the track.
        fileQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            let open = FileInspector.openAudioFiles(pid: pid)
            let picked = location.map { loc in open.first { $0.url.path == loc.path } ?? OpenFile(url: loc, size: 0) }
                ?? OpenFile.playing(among: open, trackName: title)
            let noFiles = open.isEmpty
            DispatchQueue.main.async {
                guard let self else { return }
                self.playingFile = picked
                // No file open is a stream only while Music plays; a
                // stopped Music has no file open either.
                self.isStream = picked == nil && noFiles && self.isPlaying
                self.rebuildFileInfo()
            }
        }
    }

    /// Combines the file (path, size), Music's decoder report (codec,
    /// channels) and Music's notification (title, artist, duration).
    private func rebuildFileInfo() {
        guard let f = playingFile else { file = nil; return }
        Trace.log("playing file: \(f.url.lastPathComponent)")
        var kbps: Int?
        if let ms = nowPlaying.durationMs, ms > 0, f.size > 0 {
            kbps = Int(Double(f.size) * 8 / (Double(ms) / 1000) / 1000)
        }
        file = FileInfo(title: nowPlaying.title,
                        artist: nowPlaying.artist,
                        url: f.url,
                        container: f.url.pathExtension.uppercased(),
                        codec: track.map { TrackFormat.codecName($0.codec) },
                        channels: track?.channels,
                        bitRateKbps: kbps,
                        fileSize: f.size)
    }
}
