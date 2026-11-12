import CoreAudio
import CryptoKit
import Foundation

/// A device's settings from before Bit-Perfect Listening, written to disk
/// before BitPolish changes anything, so a crash can't strand the device.
///
/// It holds the device's own settings that BitPolish changes: the physical
/// format (bit depth) and the nominal sample rate. Volume is never touched,
/// so it's never "restored" (that could only jump it up). The system's
/// output choice isn't part of a restore point: BitPolish's output moves are
/// tracked separately (SessionController.outputRevert) and undone only as
/// described there.
///
/// One file per device, keyed by the device's UID, so a restore point that is
/// waiting for an unplugged DAC is never overwritten by another device's.
struct Snapshot: Codable {
    struct StreamFormat: Codable, Equatable {
        var sampleRate: Double
        var formatID: UInt32
        var formatFlags: UInt32
        var bytesPerPacket: UInt32
        var framesPerPacket: UInt32
        var bytesPerFrame: UInt32
        var channelsPerFrame: UInt32
        var bitsPerChannel: UInt32

        init(_ f: AudioStreamBasicDescription) {
            sampleRate = f.mSampleRate; formatID = f.mFormatID; formatFlags = f.mFormatFlags
            bytesPerPacket = f.mBytesPerPacket; framesPerPacket = f.mFramesPerPacket
            bytesPerFrame = f.mBytesPerFrame; channelsPerFrame = f.mChannelsPerFrame
            bitsPerChannel = f.mBitsPerChannel
        }

        var asbd: AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: formatID, mFormatFlags: formatFlags,
                                        mBytesPerPacket: bytesPerPacket, mFramesPerPacket: framesPerPacket,
                                        mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channelsPerFrame,
                                        mBitsPerChannel: bitsPerChannel, mReserved: 0)
        }
    }

    var deviceUID: String
    var deviceName: String
    var nominalRate: Double
    var physicalFormat: StreamFormat
    var takenAt: Date

    /// Reads the device's current settings. Fails (nil) if any read fails,
    /// so a half-read snapshot can never be saved and later "restored".
    /// The format's rate and the nominal rate must agree; if they don't
    /// (another app mid-change), it re-reads briefly, because a disagreeing
    /// pair could never be verified on restore.
    static func capture(_ device: AudioDevice) -> Snapshot? {
        guard let uid = device.uid else { return nil }
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            guard let format = device.physicalFormat else { continue }
            let rate = device.nominalRate
            guard rate > 0, format.mSampleRate == rate, format.mBitsPerChannel > 0 else { continue }
            return Snapshot(deviceUID: uid, deviceName: device.name, nominalRate: rate,
                            physicalFormat: StreamFormat(format), takenAt: Date())
        }
        return nil
    }

    enum RestoreResult { case restored, deviceMissing, failed }

    /// Puts the device back and confirms it took: the write is always issued
    /// (never skipped on a read that could be stale), BitPolish waits for the
    /// device to report the restored settings, then checks once more a moment
    /// later in case an earlier change was still landing. Only `.restored`
    /// means the file may be deleted.
    ///
    /// - settleFirst: wait for the device to stop changing before restoring
    ///   (used when BitPolish's last change never confirmed).
    /// - attempts: 3 normally; 1 at quit, so quitting can't hang. A failed
    ///   restore keeps its file, and the next launch tries again.
    func restore(settleFirst: Bool = false, attempts: Int = 3) -> RestoreResult {
        guard let device = AudioDevice.find(uid: deviceUID) else { return .deviceMissing }
        if settleFirst { device.waitUntilSettled() }
        func matches() -> Bool {
            device.physicalFormat.map(StreamFormat.init) == physicalFormat && device.nominalRate == nominalRate
        }
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.3) }
            guard device.setPhysicalFormatAndWait(physicalFormat.asbd) else { continue }
            if device.nominalRate != nominalRate, !device.setNominalRateAndWait(nominalRate) { continue }
            if matches() {
                Thread.sleep(forTimeInterval: 0.25)
                if matches() { return .restored }
            }
        }
        return .failed
    }

    // MARK: Persistence

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitPolish/Restore Points", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(uid: String) -> URL {
        let digest = SHA256.hash(data: Data(uid.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest.prefix(32)).json")
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.fileURL(uid: deviceUID), options: .atomic)
    }

    static func load(uid: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(uid: uid)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Every pending restore point, oldest first.
    static func loadAll() -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.takenAt < $1.takenAt }
    }

    static func delete(uid: String) {
        try? FileManager.default.removeItem(at: fileURL(uid: uid))
    }
}
