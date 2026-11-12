import AppKit
import Foundation

/// Runs a command-line tool and returns its standard output (nil if it
/// couldn't start). Reads to the end before waiting, so a full pipe can't
/// deadlock. Call off the main thread.
enum Tool {
    static func run(_ path: String, _ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }
}

/// Apple Music, as a running app.
enum MusicApp {
    static let bundleID = "com.apple.Music"

    static var pid: pid_t? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.processIdentifier
    }

    static var isRunning: Bool { pid != nil }
}
