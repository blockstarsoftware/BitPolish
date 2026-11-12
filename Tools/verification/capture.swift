// Captures one process's audio output, as sent to the Mac's output device,
// with a CoreAudio process tap, and writes it as raw float32 interleaved
// stereo. Waits (up to 10 minutes) for the process to start playing.
//
// Usage: CaptureTest <pid> <seconds> <outfile>
//
// Build it as an app (build_capture_app.sh) so macOS's one-time "record
// audio" permission names this tool. The tap is on the output device's
// stream, so its format is the device's own (e.g. 96 kHz). Do NOT use a
// stereo-mixdown tap for this: it runs at a fixed 48 kHz and resamples.
import AppKit
import AudioToolbox
import CoreAudio
import Foundation

let args = CommandLine.arguments
let pid = pid_t(args[1])!, seconds = Double(args[2])!, outPath = args[3]
let logPath = outPath + ".log"
var logText = ""
func log(_ s: String) { logText += s + "\n"; try? logText.write(toFile: logPath, atomically: true, encoding: .utf8) }

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

// The target process's CoreAudio object.
var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
var pidVar = pid; var proc = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pidVar, &size, &proc)
log("process object \(proc) status \(st)")

// Wait (up to 10 minutes) for the process to start playing, then a moment more.
var ra = addr(kAudioProcessPropertyIsRunningOutput)
var waited = 0.0
while waited < 600 {
    var running: UInt32 = 0; var rs = UInt32(4)
    AudioObjectGetPropertyData(proc, &ra, 0, nil, &rs, &running)
    if running != 0 { break }
    Thread.sleep(forTimeInterval: 0.2); waited += 0.2
}
log("process started output after \(waited) s")
Thread.sleep(forTimeInterval: 1.0)

var da = addr(kAudioHardwarePropertyDefaultOutputDevice); var outDev = AudioDeviceID(0); size = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil, &size, &outDev)
var ua = addr(kAudioDevicePropertyDeviceUID); var uid: Unmanaged<CFString>?; size = UInt32(MemoryLayout<CFString?>.size)
AudioObjectGetPropertyData(outDev, &ua, 0, nil, &size, &uid)
let outUID = uid!.takeRetainedValue() as String
log("output device uid \(outUID)")

// Tap the process's audio headed for the output device's stream 0, so the tap's
// format is that stream's own (96 kHz here), with no mixdown resampling.
let desc = CATapDescription(processes: [proc], deviceUID: outUID, stream: 0)
desc.uuid = UUID(); desc.muteBehavior = .mutedWhenTapped; desc.isPrivate = true; desc.name = "BitPolish capture test"
var tap = AudioObjectID(0)
st = AudioHardwareCreateProcessTap(desc, &tap)
log("create tap status \(st) id \(tap)")
guard st == noErr else { exit(1) }

var fa = addr(kAudioTapPropertyFormat); var fmt = AudioStreamBasicDescription(); var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tap, &fa, 0, nil, &fs, &fmt)
log("tap format: \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, \(fmt.mBitsPerChannel)-bit, flags 0x\(String(fmt.mFormatFlags, radix: 16))")



let aggDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "BitPolish Capture Test",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: false, kAudioSubTapUIDKey: desc.uuid.uuidString]],
]
var agg = AudioObjectID(0)
st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
log("aggregate status \(st) id \(agg)")
guard st == noErr else { AudioHardwareDestroyProcessTap(tap); exit(1) }

let nonInterleaved = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
let channels = Int(fmt.mChannelsPerFrame)
var samples = [Float]()
samples.reserveCapacity(Int(fmt.mSampleRate * seconds) * channels + 4096)
let lock = NSLock()
var procID: AudioDeviceIOProcID?
st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inData, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    lock.lock(); defer { lock.unlock() }
    if nonInterleaved, list.count >= 2,
       let l = list[0].mData?.assumingMemoryBound(to: Float.self), let r = list[1].mData?.assumingMemoryBound(to: Float.self) {
        let n = Int(list[0].mDataByteSize) / 4
        for i in 0..<n { samples.append(l[i]); samples.append(r[i]) }
    } else if let p = list.first?.mData?.assumingMemoryBound(to: Float.self) {
        let n = Int(list[0].mDataByteSize) / 4
        samples.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
    }
}
log("ioproc status \(st)")
st = AudioDeviceStart(agg, procID)
log("start status \(st)")
for t in 1...Int(seconds) {
    Thread.sleep(forTimeInterval: 1)
    lock.lock(); let n = samples.count; lock.unlock()
    log("t=\(t)s frames so far \(n / max(channels, 1))")
}
lock.lock()
let early = samples.withUnsafeBufferPointer { Data(buffer: $0) }
lock.unlock()
try? early.write(to: URL(fileURLWithPath: outPath))
log("wrote capture; stopping")
AudioDeviceStop(agg, procID)
log("stopped")
if let procID { AudioDeviceDestroyIOProcID(agg, procID) }
AudioHardwareDestroyAggregateDevice(agg)
AudioHardwareDestroyProcessTap(tap)
lock.lock()
let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
lock.unlock()
try? data.write(to: URL(fileURLWithPath: outPath))
log("captured \(samples.count / max(channels, 1)) frames (\(channels) ch, non-interleaved source: \(nonInterleaved))")
log("done")
