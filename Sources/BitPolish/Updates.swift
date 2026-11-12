import AppKit
import Combine
import Sparkle

/// Software updates through Sparkle: a daily check while BitPolish runs, and
/// Check for Updates… on request. The feed address and the public signing
/// key live in Info.plist (SUFeedURL, SUPublicEDKey); until both are set,
/// updates are off and Check for Updates… says so.
///
/// BitPolish is a menu-bar app, usually in the background, so a scheduled
/// check that finds an update doesn't throw a window in front of you: the
/// panel shows a line instead, and the update window opens when you click it
/// (Sparkle's "gentle reminders").
@MainActor
final class Updates: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// The version a scheduled check found, shown in the panel until handled.
    @Published private(set) var availableVersion: String?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)

    var isConfigured: Bool {
        func value(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        }
        return !value("SUFeedURL").isEmpty && !value("SUPublicEDKey").isEmpty
    }

    /// Starts the daily check, if updates are set up in this build.
    func start() {
        guard isConfigured else { return }
        do { try controller.updater.start() } catch { NSLog("BitPolish: updates didn't start: \(error)") }
    }

    func checkForUpdates() {
        guard isConfigured else {
            activateNow()
            let alert = NSAlert()
            alert.messageText = "Updates aren't set up in this build"
            alert.informativeText = "This copy of BitPolish was built without an update feed. Downloads from the project's GitHub page check for updates automatically."
            alert.runModal()
            return
        }
        availableVersion = nil
        activateNow()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check found an update: show Sparkle's window only if
    /// BitPolish is in front already; otherwise the panel shows a line.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.availableVersion = nil }
    }
}
