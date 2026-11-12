import Foundation

/// A file a process has open, as reported by `lsof`.
public struct OpenFile: Equatable, Sendable {
    public var url: URL
    public var size: Int64

    public init(url: URL, size: Int64) {
        self.url = url
        self.size = size
    }

    static let audioExtensions: Set<String> = ["m4a", "m4p", "aif", "aiff", "wav", "flac", "mp3", "caf", "aac"]

    /// Parses `lsof -Fsn` output into the audio files it lists, with sizes.
    public static func audioFiles(fromLsof output: String) -> [OpenFile] {
        var files: [OpenFile] = []
        var seen = Set<String>()
        var size: Int64 = 0
        for line in output.split(separator: "\n") {
            switch line.first {
            case "f": size = 0                                   // new open-file entry
            case "s": size = Int64(line.dropFirst()) ?? 0
            case "n":
                let path = String(line.dropFirst())
                let url = URL(fileURLWithPath: path)
                if audioExtensions.contains(url.pathExtension.lowercased()), seen.insert(path).inserted {
                    files.append(OpenFile(url: url, size: size))
                }
            default: break
            }
        }
        return files
    }

    /// Picks the playing file. With a track name, the file whose name contains
    /// it (Music names files "NN Title.ext", replacing / and : with _). With
    /// no name, only a lone open file counts. Ambiguous means nil: showing
    /// nothing beats showing the wrong file.
    public static func playing(among files: [OpenFile], trackName: String?) -> OpenFile? {
        if let name = trackName?.lowercased(), !name.isEmpty {
            let key = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            func stem(_ f: OpenFile) -> String { f.url.deletingPathExtension().lastPathComponent.lowercased() }
            let matches = files.filter { stem($0).contains(key) }
            if matches.count == 1 { return matches[0] }
            // Long titles get truncated in file names; try the first 20 characters.
            let prefix = String(key.prefix(20))
            let loose = files.filter { stem($0).contains(prefix) }
            if loose.count == 1 { return loose[0] }
        }
        return files.count == 1 ? files[0] : nil
    }
}
