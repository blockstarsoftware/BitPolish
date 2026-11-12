import Foundation

/// What a panel notice reports, which decides when it goes away (spec v1.11,
/// Notices).
public enum NoticeKind: Sendable {
    /// Something happened while you weren't watching (a device came back and
    /// was restored, say).
    case event
    /// Still true now (a device unplugged with its restore point kept, a
    /// restore waiting to be retried).
    case pending
    /// The result of something you just did.
    case action
}

/// When a notice has run its course. Checked when the panel opens; nothing
/// runs in the background for it.
public enum NoticePolicy {
    /// An event notice stays this long after the panel first shows it...
    public static let eventShownLifetime: TimeInterval = 5 * 60
    /// ...and never longer than this after it appeared.
    public static let eventMaxAge: TimeInterval = 24 * 60 * 60

    /// True when the notice should be gone by `now`. `otherDACInUse`: a DAC
    /// other than the one a pending notice is about is now in use.
    public static func expired(kind: NoticeKind, postedAt: Date, firstShownAt: Date?, now: Date,
                               otherDACInUse: Bool) -> Bool {
        switch kind {
        case .event:
            if now.timeIntervalSince(postedAt) >= eventMaxAge { return true }
            if let shown = firstShownAt, now.timeIntervalSince(shown) >= eventShownLifetime { return true }
            return false
        case .pending:
            return otherDACInUse
        case .action:
            return false
        }
    }
}
