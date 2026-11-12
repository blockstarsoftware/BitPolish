// Shows, or sets, the physical format of the Mac's current output device.
//   swift device_format.swift                 show rate, bit depth, volume, formats offered
//   swift device_format.swift 24 96000        set 24-bit / 96 kHz (if offered)
// Setting changes your device; note its format first and set it back after testing.
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ e: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: e)
}
var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev = AudioDeviceID(0); var size = UInt32(4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
var na = addr(kAudioObjectPropertyName); var name: Unmanaged<CFString>?; size = UInt32(MemoryLayout<CFString?>.size)
AudioObjectGetPropertyData(dev, &na, 0, nil, &size, &name)
var sa = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); var ss: UInt32 = 0
AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &ss)
var streams = [AudioStreamID](repeating: 0, count: Int(ss) / 4)
AudioObjectGetPropertyData(dev, &sa, 0, nil, &ss, &streams)
guard let stream = streams.first else { print("no output stream"); exit(1) }
var fa = addr(kAudioStreamPropertyAvailablePhysicalFormats); var fs: UInt32 = 0
AudioObjectGetPropertyDataSize(stream, &fa, 0, nil, &fs)
var formats = [AudioStreamRangedDescription](repeating: .init(), count: Int(fs) / MemoryLayout<AudioStreamRangedDescription>.size)
AudioObjectGetPropertyData(stream, &fa, 0, nil, &fs, &formats)
var pa = addr(kAudioStreamPropertyPhysicalFormat)

if CommandLine.arguments.count == 3, let bits = UInt32(CommandLine.arguments[1]), let rate = Double(CommandLine.arguments[2]) {
    guard var f = formats.map(\.mFormat).first(where: {
        $0.mBitsPerChannel == bits && $0.mSampleRate == rate && $0.mFormatFlags & kAudioFormatFlagIsFloat == 0
    }) else { print("\(bits)-bit / \(rate) Hz isn't offered by this device"); exit(1) }
    let st = AudioObjectSetPropertyData(stream, &pa, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &f)
    print("set \(bits)-bit / \(Int(rate)) Hz: status \(st)")
    Thread.sleep(forTimeInterval: 1)
}
var cur = AudioStreamBasicDescription(); var cs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(stream, &pa, 0, nil, &cs, &cur)
print("device: \(name?.takeRetainedValue() as String? ?? "?")")
print("physical format: \(cur.mBitsPerChannel)-bit, \(Int(cur.mSampleRate)) Hz, float=\(cur.mFormatFlags & kAudioFormatFlagIsFloat != 0)")
print("offered: " + Set(formats.map { "\($0.mFormat.mBitsPerChannel)-bit@\(Int($0.mFormat.mSampleRate))" }).sorted().joined(separator: ", "))
for e in UInt32(0)...8 {
    var va = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, e)
    guard AudioObjectHasProperty(dev, &va) else { continue }
    var v: Float32 = 0; var vs = UInt32(4); AudioObjectGetPropertyData(dev, &va, 0, nil, &vs, &v)
    print("volume element \(e): \(v) (1.0 = unity)")
}
