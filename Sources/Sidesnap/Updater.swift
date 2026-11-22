import AppKit
import Sparkle

/// One-click updates, powered by Sparkle (https://sparkle-project.org).
///
/// What goes over the internet: once a day (if "Check for updates
/// automatically" is on) or when you choose "Check for Updates…", Sidesnap
/// downloads one small file, the update feed (SUFeedURL in Info.plist). If a
/// newer version is listed, Sparkle asks before downloading it. Nothing about
/// you or your screenshots is sent; system profiling is off.
///
/// Every update must carry a signature made with Sidesnap's private update key
/// (SUPublicEDKey in Info.plist is the public half). Anything else is refused.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// The version offered by the latest check, if newer than this one.
    @Published private(set) var availableVersion: String?
    @Published var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }

    private var controller: SPUStandardUpdaterController!

    override init() {
        checksAutomatically = true
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    /// "Check for Updates…" / "Install Update" in the menu.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // Sidesnap lives in the menu bar with no windows, so let Sparkle show a
    // found update gently; the menu also gets an "Install Update" row.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
