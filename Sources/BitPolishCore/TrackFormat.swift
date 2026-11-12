import Foundation

/// The format of the track Apple Music is decoding, as its decoder reports it.
public struct TrackFormat: Equatable, Sendable {
    public var sampleRate: Double
    /// Source bit depth; 0 for lossy codecs, which don't have one.
    public var bitDepth: Int
    public var channels: Int
    /// Codec token from the log, e.g. "alac", "aac ".
    public var codec: String

    public init(sampleRate: Double, bitDepth: Int, channels: Int = 2, codec: String = "") {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.codec = codec
    }

    /// Parses one of Music's decoder log lines:
    /// "Input format:  2 ch,  96000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet".
    /// Lossy codecs omit "from N-bit source". Returns nil for any other line.
    public static func parse(logLine line: String) -> TrackFormat? {
        guard let input = line.range(of: "Input format:") else { return nil }
        let rest = String(line[input.upperBound...])
        guard let hz = rest.range(of: #"(\d+) Hz"#, options: .regularExpression),
              let rate = Double(rest[hz].split(separator: " ")[0]), rate > 0 else { return nil }
        var channels = 2
        if let ch = rest.range(of: #"(\d+) ch"#, options: .regularExpression) {
            channels = Int(rest[ch].split(separator: " ")[0]) ?? 2
        }
        var depth = 0
        if let bits = rest.range(of: #"from (\d+)-bit source"#, options: .regularExpression) {
            depth = Int(rest[bits].split(separator: " ")[1].replacingOccurrences(of: "-bit", with: "")) ?? 0
        }
        // The codec token sits between "Hz, " and " (0x".
        var codec = ""
        let afterHz = rest[hz.upperBound...].drop { $0 == "," || $0 == " " }
        if let paren = afterHz.range(of: " (") { codec = String(afterHz[..<paren.lowerBound]) }
        return TrackFormat(sampleRate: rate, bitDepth: depth, channels: channels, codec: codec)
    }

    /// Readable name for a codec token ("alac" -> "Apple Lossless (ALAC)").
    public static func codecName(_ token: String) -> String {
        switch token.trimmingCharacters(in: .whitespaces).lowercased() {
        case "alac": return "Apple Lossless (ALAC)"
        case "aac", "aach", "aacp": return "AAC"
        case "flac": return "FLAC"
        case ".mp3": return "MP3"
        case "lpcm": return "PCM (uncompressed)"
        case let other: return other.uppercased()
        }
    }

    /// The rate to run the device at for a track: the track's own rate if the
    /// device offers it; otherwise the smallest offered rate above it (so
    /// nothing is lost), else the highest offered. With no track, `current`.
    public static func outputRate(for trackRate: Double?, supported: [Double], current: Double) -> Double {
        guard let trackRate, !supported.isEmpty else { return trackRate ?? current }
        if supported.contains(trackRate) { return trackRate }
        return supported.sorted().first { $0 > trackRate } ?? supported.max() ?? current
    }

    /// Parses the track title from Music's playback log line, logged as each
    /// track starts: "... tracksDidChange: - item=<ITMPAVItem: 0x...> (707791::726451)
    /// The Full Bug  (2015 Remaster) - timeStamp:15844". Nil for any other line.
    public static func trackTitle(logLine line: String) -> String? {
        guard let item = line.range(of: "tracksDidChange: - item=<") else { return nil }
        let rest = line[item.upperBound...]
        guard let close = rest.range(of: ") "), let end = rest.range(of: " - timeStamp:", options: .backwards),
              close.upperBound <= end.lowerBound else { return nil }
        let title = rest[close.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
