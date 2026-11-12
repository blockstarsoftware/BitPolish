// Prints a millisecond timestamp whenever the Mac's output device changes
// rate or bit depth. Read-only. Run alongside Music to time rate switches:
//   swift ratewatch.swift 180     (watch for 180 s)
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev = AudioDeviceID(0); var size = UInt32(4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
var sa = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); var ss: UInt32 = 0
AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &ss)
var streams = [AudioStreamID](repeating: 0, count: Int(ss) / 4)
AudioObjectGetPropertyData(dev, &sa, 0, nil, &ss, &streams)
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
var last = ""
let end = Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "") ?? 180)
while Date() < end {
    var ra = addr(kAudioDevicePropertyNominalSampleRate); var rate: Float64 = 0; var rs = UInt32(8)
    AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &rate)
    var pa = addr(kAudioStreamPropertyPhysicalFormat); var f = AudioStreamBasicDescription()
    var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    if let s = streams.first { AudioObjectGetPropertyData(s, &pa, 0, nil, &fs, &f) }
    let now = "\(f.mBitsPerChannel)-bit / \(Int(rate)) Hz"
    if now != last { print("\(fmt.string(from: Date()))  device -> \(now)"); fflush(stdout); last = now }
    usleep(5000)
}
