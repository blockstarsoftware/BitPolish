import Foundation
import BitPolishCore

/// Watches Apple Music two ways:
///  1. Music's CoreAudio log, where each of its decoders reports a track's
///     sample rate, source bit depth and codec as it starts decoding.
///  2. Music's `com.apple.Music.playerInfo` notification for play, pause,
///     and track changes.
///
/// Music decodes a track a moment before it plays (ahead of the track change
/// for gapless playback, and sometimes just before Music announces a track
/// you picked), so a decoder line can arrive early. Such a line is held, and
/// applied the instant Music announces the next track, so the DAC switches
/// rate at the track's start. For the first few seconds of a track its own
/// decoder line is still authoritative: if it differs from the held guess
/// (you skipped to an unexpected track), it corrects the rate at once.
@MainActor
final class MusicWatcher {
    var onFormat: ((TrackFormat) -> Void)?
    var onPlayerState: ((_ playing: Bool) -> Void)?
    /// A new track started. Carries Music's notification payload (name, artist,
    /// and for local files usually a "Location" file URL).
    var onTrackChange: ((_ info: [AnyHashable: Any]) -> Void)?
    /// Called once if macOS refuses to let this account read the log
    /// (`log` allows streaming only for administrator accounts).
    var onLogDenied: (() -> Void)?
    /// At launch, the title of the track Music was already playing, recovered
    /// from Music's log (Music's notifications only arrive on changes).
    var onRecoveredTitle: ((String) -> Void)?

    private var process: Process?
    private var shouldRun = false
    private var logDenied = false
    private var restartDelay: TimeInterval = 1
    private var buffer = Data()
    private var lastTrackID: String?
    private var isPlaying = false
    /// Bumped on every track change, so a slow look-back can't apply an old
    /// track's format to a new one.
    private var trackGeneration = 0
    /// True from a track change (or launch) until that track's format is known.
    private var awaitingFormat = true
    private var pending: (format: TrackFormat, at: Date)?
    /// Set when a held guess was applied at a track change; the track's own
    /// decoder line, if it arrives within `correctionWindow`, still counts.
    private var guessedAt: Date?
    private var lastApplied: TrackFormat?
    private let correctionWindow: TimeInterval = 3
    /// After a track change, how long its own decoder line may take. Music
    /// logs a line only when it needs a new decoder, so a track in the same
    /// format as the last logs none; past this, later lines are the next
    /// track decoding ahead and are held.
    private let firstLineWindow: TimeInterval = 4

    /// Every Music decoder (Apple Lossless, AAC, MP3...) logs an "Input format" line.
    nonisolated static let predicate = #"(subsystem == "com.apple.coreaudio") AND (process == "Music") AND (eventMessage CONTAINS "Decoder") AND (eventMessage CONTAINS "Input format")"#

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        awaitingFormat = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfo(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        reapOrphanedStreams()
        launchStream()
        catchUp()
    }

    func stop() {
        shouldRun = false
        DistributedNotificationCenter.default().removeObserver(self)
        process?.terminate()
        process = nil
        pending = nil
        guessedAt = nil
        buffer.removeAll()
    }

    /// Forgets a format decoded ahead of time (used when the DAC is primed:
    /// anything decoded before then was for a track the user isn't choosing).
    func discardHeld() {
        pending = nil
    }

    /// Music quit or crashed, so no "Stopped" notification is coming. Forget
    /// the playing state so the next launch starts clean.
    func musicQuit() {
        pending = nil
        guessedAt = nil
        lastTrackID = nil
        awaitingFormat = true
        if isPlaying {
            isPlaying = false
            onPlayerState?(false)
        }
    }

    /// If BitPolish was force-quit, its `log stream` helper keeps running with
    /// no parent. Ends any such orphan: only this user's processes whose
    /// parent is launchd and whose command is exactly BitPolish's own stream.
    private func reapOrphanedStreams() {
        guard let data = Tool.run("/bin/ps", ["-x", "-o", "pid=,ppid=,command="]) else { return }
        let ours = "/usr/bin/log stream --style compact --predicate " + Self.predicate
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), parts[1] == "1",
                  parts[2].trimmingCharacters(in: .whitespaces) == ours else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// Runs `log stream`. If it exits (e.g. a logd restart), it's restarted
    /// with a growing delay, up to 30 s. If macOS refuses this account, it
    /// says so once and stops trying.
    private func launchStream() {
        #if BITPOLISH_TESTING
        if TestHooks.simulateNoLog { denyLog(); return }
        #endif
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate", Self.predicate]
        let output = Pipe()
        p.standardOutput = output
        // Watch stderr for macOS's refusal ("Must be admin to run 'stream'
        // command"), so a standard account gets an explanation instead of a
        // switch that silently never follows the music.
        let errors = Pipe()
        p.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("must be admin") {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.denyLog() } }
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil   // end of stream; stop polling
                return
            }
            // FIFO onto main, so chunks are parsed in the order they arrived.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(data) } }
        }
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.shouldRun, self.process === ended else { return }
                    self.process = nil
                    if !self.logDenied { self.scheduleRestart() }   // refused: retrying won't help
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("BitPolish: could not start log stream: \(error)")
            scheduleRestart()
        }
    }

    private func denyLog() {
        guard !logDenied else { return }
        logDenied = true
        process?.terminate()
        process = nil
        onLogDenied?()
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shouldRun, self.process == nil else { return }
                self.launchStream()
            }
        }
    }

    /// Music logs each track's title as it starts (its playback engine's
    /// "tracksDidChange" line).
    nonisolated static let titlePredicate = #"(subsystem == "com.apple.amp.mediaplaybackcore") AND (process == "Music") AND (eventMessage CONTAINS "tracksDidChange: - item=")"#

    /// At launch, nothing is coming for a track that's already playing until
    /// the next track: no decoder line, and no notification with its title.
    /// Look back through the recent log for both. Music logs a decoder line
    /// only when it needs a new decoder, so a run of same-format tracks
    /// logs one line, possibly long ago; hence the long look-back. (Near a
    /// track's end the last decoder line may already be the next track's
    /// pre-decode; that self-corrects at the next track.)
    private func catchUp() {
        guard MusicApp.isRunning else { return }
        let predicate = "(\(Self.predicate)) OR (\(Self.titlePredicate))"
        let startedFor = trackGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = Tool.run("/usr/bin/log", ["show", "--last", "3h", "--style", "compact", "--predicate", predicate]) else { return }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed().map(String.init)
            let format = lines.lazy.compactMap { TrackFormat.parse(logLine: $0) }.first
            let title = lines.lazy.compactMap { TrackFormat.trackTitle(logLine: $0) }.first
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.shouldRun, self.trackGeneration == startedFor else { return }
                    if let title { self.onRecoveredTitle?(title) }
                    if let format, self.awaitingFormat {
                        self.awaitingFormat = false
                        self.apply(format)
                    }
                }
            }
        }
    }

    // MARK: Log lines

    /// Splits on newline bytes, so a chunk that ends mid-character is kept
    /// whole until the rest arrives.
    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            restartDelay = 1   // the stream is healthy
            if let format = TrackFormat.parse(logLine: line) { detected(format) }
        }
    }

    private func detected(_ format: TrackFormat) {
        if awaitingFormat {
            // The current track's first decoder line.
            awaitingFormat = false
            pending = nil
            apply(format)
        } else if let guessedAt, Date().timeIntervalSince(guessedAt) < correctionWindow {
            // The track's own line right after a guessed switch: it wins.
            self.guessedAt = nil
            pending = nil
            if format != lastApplied { apply(format) }
        } else {
            // Music decoding ahead (the next track, or one about to be
            // announced). Hold it.
            pending = (format, Date())
        }
    }

    private func apply(_ format: TrackFormat) {
        lastApplied = format
        onFormat?(format)
    }

    // MARK: Player notifications

    @objc private func playerInfo(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let playing = (info["Player State"] as? String) == "Playing"
        let trackID = (info["PersistentID"] ?? info["Persistent ID"]).map { "\($0)" }
            ?? "\(info["Name"] ?? "")|\(info["Artist"] ?? "")"

        if playing && trackID != lastTrackID {
            lastTrackID = trackID
            trackGeneration += 1
            awaitingFormat = true
            guessedAt = nil
            if let held = pending, Date().timeIntervalSince(held.at) < 600 {
                // Switch now, at the track's start; its own decoder line can
                // still correct this for the next few seconds.
                awaitingFormat = false
                guessedAt = Date()
                apply(held.format)
            }
            pending = nil
            if awaitingFormat {
                // No line within the window: same format as before.
                let generation = trackGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + firstLineWindow) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.trackGeneration == generation else { return }
                        self.awaitingFormat = false
                    }
                }
            }
            onTrackChange?(info)
        }
        if playing != isPlaying {
            isPlaying = playing
            onPlayerState?(playing)
        }
    }
}
