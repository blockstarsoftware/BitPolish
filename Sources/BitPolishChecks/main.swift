// Checks for BitPolish's pure logic. Runs with only the Command Line Tools:
//
//     swift run BitPolishChecks
//
// Exits non-zero if any check fails.

import Foundation
import BitPolishCore

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String, line: Int = #line) {
    if condition() { print("ok    \(label)") } else { failures += 1; print("FAIL  \(label)  (line \(line))") }
}

// Decoder log lines, as Music writes them.
let alac = "2026-10-15 22:07:03.053 Df Music[747:1677df] [com.apple.coreaudio:ac] ACAppleLosslessDecoder.cpp:681   (0x767765afc0) Input format:  2 ch,  96000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet"
let cd = "ACAppleLosslessDecoder.cpp:681   (0x767c9c82c0) Input format:  2 ch,  44100 Hz, alac (0x00000001) from 16-bit source, 4096 frames/packet"
let aac = "ACMP4AACBaseDecoder.cpp:1337  (0x1) Input format:  2 ch,  44100 Hz, aac  (0x00000000) 0 bits/channel, 0 bytes/packet"
let output = "ACAppleLosslessDecoder.cpp:684   (0x767c9c82c0) Output format:  2 ch,  44100 Hz, Int16, interleaved"

check(TrackFormat.parse(logLine: alac) == TrackFormat(sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "alac"), "parses a 24/96 ALAC line")
check(TrackFormat.parse(logLine: cd)?.bitDepth == 16, "parses a 16/44.1 ALAC line")
check(TrackFormat.parse(logLine: aac).map { $0.sampleRate == 44_100 && $0.bitDepth == 0 } == true, "parses a lossy line with no bit depth")
check(TrackFormat.parse(logLine: output) == nil, "ignores Output format lines")
check(TrackFormat.parse(logLine: "unrelated") == nil, "ignores unrelated lines")

check(TrackFormat.codecName("alac") == "Apple Lossless (ALAC)", "names ALAC")
check(TrackFormat.codecName("aac ") == "AAC", "names AAC with trailing space")

// Rate choice on a device offering 44.1, 48, 96, 192 (the USB SPDIF adapter).
let rates: [Double] = [44_100, 48_000, 96_000, 192_000]
check(TrackFormat.outputRate(for: 96_000, supported: rates, current: 44_100) == 96_000, "keeps a supported rate")
check(TrackFormat.outputRate(for: 88_200, supported: rates, current: 44_100) == 96_000, "88.2 goes up to 96")
check(TrackFormat.outputRate(for: 352_800, supported: rates, current: 44_100) == 192_000, "above the top goes to the highest")
check(TrackFormat.outputRate(for: nil, supported: rates, current: 48_000) == 48_000, "no track keeps the current rate")
check(TrackFormat.outputRate(for: 88_200, supported: [96_000, 44_100], current: 44_100) == 96_000, "unsorted rate lists work")

// Picking the playing file among Music's open files.
let current = OpenFile(url: URL(fileURLWithPath: "/m/1-07 Seasons Of Wither (GH Edit).m4a"), size: 1)
let next = OpenFile(url: URL(fileURLWithPath: "/m/1-08 Draw The Line.m4a"), size: 1)
check(OpenFile.playing(among: [current, next], trackName: "Seasons Of Wither (GH Edit)") == current, "matches by track name")
check(OpenFile.playing(among: [current, next], trackName: nil) == nil, "two files and no name is ambiguous")
check(OpenFile.playing(among: [current], trackName: nil) == current, "a lone file is the playing one")
check(OpenFile.playing(among: [OpenFile(url: URL(fileURLWithPath: "/m/01 AC_DC Song.m4a"), size: 1)], trackName: "AC/DC Song") != nil, "slash in a title maps to underscore")

let lsof = "p747\nf12\ns1048576\nn/m/1-07 Seasons.m4a\nf13\nn/System/Library/x.dylib\nf14\ns2\nn/m/next.flac\n"
check(OpenFile.audioFiles(fromLsof: lsof).map(\.size) == [1_048_576, 2], "parses lsof output, audio files only")

// Track title from Music's playback log.
let playback = "2026-10-16 21:15:53.301 Df Music[69716:2a09f0] [com.apple.amp.mediaplaybackcore:Playback] [myGt0wAod]-<_MPCPlaybackEnginePlayer: 0x771c477000> - tracksDidChange: - item=<ITMPAVItem: 0x7729759c00> (707791::726451) The Full Bug  (2015 Remaster) - timeStamp:15844"
check(TrackFormat.trackTitle(logLine: playback) == "The Full Bug  (2015 Remaster)", "parses the track title from the playback log")
check(TrackFormat.trackTitle(logLine: playback.replacingOccurrences(of: "The Full Bug", with: "A - B")) == "A - B  (2015 Remaster)", "a title containing a dash survives")
check(TrackFormat.trackTitle(logLine: "STATE MACHINE: Received player event: tracksDidChange:<AVPlayerItem: 0x1> I/TZV") == nil, "ignores the state-machine line")

// Manually Prime DAC rows.
let adapter = Priming.rows(supported: rates)
check(adapter.map { $0.map(\.rate) } == [[44_100, 88_200, 176_400], [48_000, 96_000, 192_000]], "priming: two family rows up to 192")
check(adapter[0].map(\.supported) == [true, false, false] && adapter[1].allSatisfy(\.supported), "priming: 88.2 and 176.4 unsupported on the adapter")
check(adapter[0][1].playsAt == 96_000 && adapter[0][2].playsAt == 192_000, "priming: unsupported rates play at the next rate up")
let hugo = Priming.rows(supported: Priming.standardRates)
check(hugo.map(\.count) == [5, 5] && hugo.allSatisfy { $0.allSatisfy(\.supported) }, "priming: a 768 kHz DAC fills both rows")
check(Priming.rows(supported: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]).map(\.count) == [4, 4], "priming: a 384 kHz DAC gets four columns")
check(Priming.rows(supported: [44_100, 48_000]).map(\.count) == [3, 3], "priming: a 48 kHz DAC still shows columns to 192")
check(Priming.rows(supported: []).isEmpty, "priming: no rates, no rows")

// Bit depth choices.
check(BitDepth.choices(deviceMax: 32) == [24, 32] && BitDepth.choices(deviceMax: 24) == [24], "bit depth: 24 plus a higher maximum")
check(BitDepth.choices(deviceMax: 16) == [16] && BitDepth.choices(deviceMax: 0).isEmpty, "bit depth: a 16-bit device offers only 16")
check(BitDepth.resolve(stored: nil, deviceMax: 32) == 24 && BitDepth.resolve(stored: nil, deviceMax: 16) == 16, "bit depth: defaults to 24, or the device maximum if lower")
check(BitDepth.resolve(stored: 32, deviceMax: 32) == 32 && BitDepth.resolve(stored: 32, deviceMax: 24) == 24, "bit depth: a stored choice applies only while offered")
check(BitDepth.joinedLabel(["24-bit", "32-bit"]) == "24- and 32-bit" && BitDepth.joinedLabel(["24-bit"]) == "24-bit", "details: bit depths sharing rates join")
check(BitDepth.joinedLabel(["16-bit", "24-bit", "32-bit"]) == "16-, 24- and 32-bit" && BitDepth.joinedLabel(["24-bit", "32-bit float"]) == "24-bit and 32-bit float", "details: three depths, and float kept whole")

check(Format.rate(44_100) == "44.1" && Format.rate(48_000) == "48" && Format.rate(176_400) == "176.4", "formats rates")

// Notices: when each kind goes away.
let t0 = Date(timeIntervalSinceReferenceDate: 0)
func expired(_ kind: NoticeKind, shownAfter shown: TimeInterval? = nil, at now: TimeInterval, otherDAC: Bool = false) -> Bool {
    NoticePolicy.expired(kind: kind, postedAt: t0, firstShownAt: shown.map { t0 + $0 }, now: t0 + now, otherDACInUse: otherDAC)
}
check(!expired(.event, at: 3_600), "notices: an event stays until the panel shows it")
check(!expired(.event, shownAfter: 60, at: 60 + 4 * 60) && expired(.event, shownAfter: 60, at: 60 + 5 * 60), "notices: an event goes 5 minutes after it was first shown")
check(expired(.event, at: 24 * 3_600), "notices: an event goes after 24 hours, even unseen")
check(!expired(.pending, shownAfter: 0, at: 48 * 3_600) && expired(.pending, at: 1, otherDAC: true), "notices: a pending one stays while true, and goes when another DAC is in use")
check(!expired(.action, shownAfter: 0, at: 48 * 3_600, otherDAC: true), "notices: an action result stays until the next action")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
