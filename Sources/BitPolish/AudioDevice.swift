import BitPolishCore
import CoreAudio
import Foundation

/// Thin wrapper over a CoreAudio output device. Every read and write BitPolish
/// performs on the hardware goes through here.
struct AudioDevice: Equatable {
    let id: AudioDeviceID

    // MARK: Property plumbing

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var addr = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    private static func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var addr = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.size)
        let status = items.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!)
        }
        // The list can shrink between the two calls; keep only what was returned.
        return status == noErr ? Array(items.prefix(Int(size) / MemoryLayout<T>.size)) : []
    }

    @discardableResult
    private static func set<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var addr = addr
        var value = value
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    private static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    // MARK: Discovery

    static func allOutputDevices() -> [AudioDevice] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioDeviceID(0))
        return ids.map(AudioDevice.init).filter { !$0.outputStreams.isEmpty }
    }

    static func defaultOutput() -> AudioDevice? {
        guard let id = get(AudioObjectID(kAudioObjectSystemObject),
                           address(kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)), id != 0 else { return nil }
        return AudioDevice(id: id)
    }

    /// Devices the user could choose as the Mac's sound output: can be the
    /// default output and aren't hidden (apps' private aggregates are).
    static func choosableOutputs() -> [AudioDevice] {
        allOutputDevices().filter { d in
            let canBeDefault = get(d.id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0
            let hidden = get(d.id, address(kAudioDevicePropertyIsHidden), UInt32(0)) ?? 0
            return canBeDefault != 0 && hidden == 0
        }
    }

    /// Makes `device` the Mac's sound output, the setting the Sound menu
    /// changes. Returns true once macOS reports it.
    @discardableResult
    static func setDefaultOutput(_ device: AudioDevice) -> Bool {
        let addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard set(AudioObjectID(kAudioObjectSystemObject), addr, device.id) == noErr else { return false }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if defaultOutput() == device { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return defaultOutput() == device
    }

    static func find(uid: String) -> AudioDevice? {
        allOutputDevices().first { $0.uid == uid }
    }

    // MARK: Per-process playback state (macOS 14+)

    /// CoreAudio's object for a client process, e.g. Music, if it has one.
    static func processObject(pid: pid_t) -> AudioObjectID? {
        let objects = getArray(AudioObjectID(kAudioObjectSystemObject),
                               address(kAudioHardwarePropertyProcessObjectList), AudioObjectID(0))
        return objects.first { get($0, address(kAudioProcessPropertyPID), pid_t(0)) == pid }
    }

    /// Whether that process is currently sending audio out. No permission needed.
    static func isRunningOutput(processObject: AudioObjectID) -> Bool {
        (get(processObject, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
    }

    /// Calls `handler` on the main queue when that process starts or stops output.
    static func observeRunningOutput(processObject: AudioObjectID, _ handler: @escaping @Sendable () -> Void) -> () -> Void {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var addr = address(kAudioProcessPropertyIsRunningOutput)
        guard AudioObjectAddPropertyListenerBlock(processObject, &addr, .main, block) == noErr else { return {} }
        return {
            var addr = address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(processObject, &addr, .main, block)
        }
    }

    // MARK: Transport (is this an external DAC connection?)

    var transportType: UInt32 {
        Self.get(id, Self.address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    }

    /// Why Bit-Perfect Listening can't run on this output, or nil if it can.
    /// Built-in hardware isn't an external DAC; Bluetooth and AirPlay
    /// re-encode the audio, so bit-perfect output is impossible over them;
    /// virtual and aggregate devices are software, not DACs.
    var ineligibility: (short: String, reason: String)? {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return ("Built-in", "Bit-Perfect Listening needs an external DAC. Choose yours in System Settings › Sound › Output; the Mac's built-in output isn't one.")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return ("Bluetooth", "Bluetooth re-encodes the audio, so bit-perfect playback isn't possible over it. Choose a wired DAC in System Settings › Sound › Output.")
        case kAudioDeviceTransportTypeAirPlay:
            return ("AirPlay", "AirPlay re-encodes the audio, so bit-perfect playback isn't possible over it. Choose a wired DAC in System Settings › Sound › Output.")
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return ("Virtual", "This output is a software device, not a DAC. Choose a wired DAC in System Settings › Sound › Output.")
        default:
            return nil   // USB, HDMI, DisplayPort, Thunderbolt, FireWire, PCI, unknown
        }
    }

    // MARK: System-level change listeners

    /// Calls `handler` on the main queue when the default output device
    /// changes or a device is connected or disconnected.
    static func observeSystemOutputChanges(_ handler: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    /// Whether this device is still connected.
    var isAlive: Bool {
        (Self.get(id, Self.address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)) ?? 0) != 0
            && Self.allOutputDevices().contains(self)
    }

    // MARK: Identity

    var name: String { Self.getString(id, kAudioObjectPropertyName) ?? "Unknown device" }
    var uid: String? { Self.getString(id, kAudioDevicePropertyDeviceUID) }

    // MARK: Sample rate

    var nominalRate: Double {
        Self.get(id, Self.address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    var availableRates: [Double] {
        let ranges = Self.getArray(id, Self.address(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
        var rates = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum {
                rates.insert(r.mMinimum)
            } else {
                // A continuous range: offer every standard rate inside it.
                rates.formUnion(Priming.standardRates.filter { $0 >= r.mMinimum && $0 <= r.mMaximum })
            }
        }
        return rates.sorted()
    }

    private func setNominalRate(_ rate: Double) -> Bool {
        Self.set(id, Self.address(kAudioDevicePropertyNominalSampleRate), Float64(rate)) == noErr
    }

    // MARK: Streams and physical format (bit depth)

    var outputStreams: [AudioStreamID] {
        Self.getArray(id, Self.address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID(0))
    }

    var physicalFormat: AudioStreamBasicDescription? {
        guard let stream = outputStreams.first else { return nil }
        return Self.get(stream, Self.address(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription())
    }

    var availablePhysicalFormatRanges: [AudioStreamRangedDescription] {
        guard let stream = outputStreams.first else { return [] }
        return Self.getArray(stream, Self.address(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription())
    }

    var isFloat: Bool { (physicalFormat?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0 }

    /// Bit depth of the current physical format, or 0 if unknown.
    var bitDepth: Int { Int(physicalFormat?.mBitsPerChannel ?? 0) }

    private func setPhysicalFormat(_ format: AudioStreamBasicDescription) -> Bool {
        guard let stream = outputStreams.first else { return false }
        return Self.set(stream, Self.address(kAudioStreamPropertyPhysicalFormat), format) == noErr
    }

    /// Sets the physical format and waits until the device reports it.
    /// CoreAudio applies a format change asynchronously: right after the set,
    /// reads can still return the old format. Anything that reads or changes
    /// the device next (a restore, a capture) must start from the settled
    /// state, so callers wait here. Hardware queue only.
    @discardableResult
    func setPhysicalFormatAndWait(_ format: AudioStreamBasicDescription, timeout: TimeInterval = 2) -> Bool {
        guard setPhysicalFormat(format) else { return false }   // refused: don't wait out the timeout
        return waitUntil(timeout: timeout) { self.physicalFormat == format && self.nominalRate == format.mSampleRate }
    }

    /// Sets the nominal rate and waits until the device reports it.
    @discardableResult
    func setNominalRateAndWait(_ rate: Double, timeout: TimeInterval = 2) -> Bool {
        guard setNominalRate(rate) else { return false }
        return waitUntil(timeout: timeout) { self.nominalRate == rate }
    }

    /// Waits until the device's format and rate have stopped changing for
    /// `quiet` seconds (or `timeout` passes). Used before a restore after a
    /// change that never confirmed, so a late-landing change can't slip in
    /// after the restore is verified.
    func waitUntilSettled(quiet: TimeInterval = 0.4, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = (physicalFormat, nominalRate)
        var stableSince = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let now = (physicalFormat, nominalRate)
            if now.0 != last.0 || now.1 != last.1 { last = now; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) >= quiet { return }
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    /// The deepest integer PCM format at `rate` with at most `maxBits` bits,
    /// matching the current channel count: what the bit depth lock sets.
    /// Formats listed for "any rate" (sample rate 0, with a rate range) count
    /// if the range covers `rate`; non-mixable formats are skipped. Ties go to
    /// the tighter packing, so the choice is the same every time.
    func integerFormat(at rate: Double, maxBits: Int) -> AudioStreamBasicDescription? {
        let candidates: [AudioStreamBasicDescription] = lockableFormatRanges.compactMap { ranged in
            var f = ranged.mFormat
            if f.mSampleRate == rate { return f }
            if f.mSampleRate == kAudioStreamAnyRate,
               ranged.mSampleRateRange.mMinimum <= rate, rate <= ranged.mSampleRateRange.mMaximum {
                f.mSampleRate = rate
                return f
            }
            return nil
        }
        return candidates.filter { Int($0.mBitsPerChannel) <= maxBits }.max { a, b in
            a.mBitsPerChannel != b.mBitsPerChannel ? a.mBitsPerChannel < b.mBitsPerChannel
                                                   : a.mBytesPerFrame > b.mBytesPerFrame
        }
    }

    /// Formats the bit-depth lock may use: integer linear PCM, mixable, with
    /// the current channel count.
    private var lockableFormatRanges: [AudioStreamRangedDescription] {
        let channels = physicalFormat?.mChannelsPerFrame ?? 2
        return availablePhysicalFormatRanges.filter { r in
            let f = r.mFormat
            return f.mFormatID == kAudioFormatLinearPCM
                && f.mFormatFlags & kAudioFormatFlagIsFloat == 0
                && f.mFormatFlags & kAudioFormatFlagIsNonMixable == 0
                && f.mChannelsPerFrame == channels
        }
    }

    /// Highest bit depth the lock can use (the top bit-depth choice), from the
    /// same formats `integerFormat(at:maxBits:)` chooses among.
    var maxIntegerBitDepth: Int {
        lockableFormatRanges.map { Int($0.mFormat.mBitsPerChannel) }.max() ?? 0
    }

    // MARK: Change listeners

    /// Calls `handler` on the main queue whenever the device's rate, its
    /// output stream's physical format, or its volume changes, whoever
    /// changed it. Returns a closure that removes the listeners.
    func observeFormatChanges(_ handler: @escaping @Sendable () -> Void) -> () -> Void {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var registrations: [(AudioObjectID, AudioObjectPropertyAddress)] = []
        var rateAddr = Self.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(id, &rateAddr, .main, block) == noErr {
            registrations.append((id, rateAddr))
        }
        if let stream = outputStreams.first {
            var fmtAddr = Self.address(kAudioStreamPropertyPhysicalFormat)
            if AudioObjectAddPropertyListenerBlock(stream, &fmtAddr, .main, block) == noErr {
                registrations.append((stream, fmtAddr))
            }
        }
        // Volume too: on many devices this is the macOS volume slider.
        for element in volumeElements {
            var volAddr = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            if AudioObjectAddPropertyListenerBlock(id, &volAddr, .main, block) == noErr {
                registrations.append((id, volAddr))
            }
        }
        return {
            for (object, addr) in registrations {
                var addr = addr
                AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
            }
        }
    }

    // MARK: Volume

    /// Output volume elements that exist on this device (0 = master, 1..n = channels).
    var volumeElements: [UInt32] {
        (0...8).map(UInt32.init).filter { element in
            var addr = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
            return AudioObjectHasProperty(id, &addr)
        }
    }

    func volume(element: UInt32) -> Float32? {
        Self.get(id, Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element), Float32(0))
    }

    /// True when every volume control is all the way up (or there are none),
    /// so the device passes samples through at unity gain.
    var volumeIsFull: Bool {
        volumeElements.allSatisfy { (volume(element: $0) ?? 1) >= 0.9999 }
    }
}

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (a: AudioStreamBasicDescription, b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mBytesPerPacket == b.mBytesPerPacket
            && a.mFramesPerPacket == b.mFramesPerPacket
    }
}
