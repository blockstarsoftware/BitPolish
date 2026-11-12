import Foundation
import BitPolishCore

/// What the Playing File section shows. Assembled without ever opening the
/// file: Apple Music's library folder is privacy-protected, and reading a file
/// inside it triggers a Media Library permission prompt. So:
///  - codec and channels: Music's decoder log line
///  - file path and size: `lsof` on Music (the kernel's list of its open files)
///  - title, artist, duration: Music's track-change notification
/// (Sample rate and bit depth are shown in the Source/DAC rows.)
struct FileInfo: Equatable {
    var title: String?
    var artist: String?
    /// Where the file is, for Show in Finder. Never opened by BitPolish.
    var url: URL
    var container: String      // "M4A", "AIFF", "WAV" ...
    var codec: String?         // "Apple Lossless (ALAC)", "AAC" ... nil if Music didn't report one
    var channels: Int?
    var bitRateKbps: Int?
    var fileSize: Int64
}

enum FileInspector {
    /// Audio files a process has open, with sizes, via `lsof`. Reads the
    /// kernel's open-file table only; no file is opened and no permission is
    /// needed for the user's own processes. Music usually has two open: the
    /// playing track and the next one, pre-loaded for gapless playback.
    static func openAudioFiles(pid: pid_t) -> [OpenFile] {
        guard let data = Tool.run("/usr/sbin/lsof", ["-Fsn", "-p", String(pid)]) else { return [] }
        return OpenFile.audioFiles(fromLsof: String(decoding: data, as: UTF8.self))
    }
}
