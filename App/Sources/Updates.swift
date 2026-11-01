import AppKit
import Sparkle

/// Atualizações pelo Sparkle: `docs/appcast.xml` no GitHub Pages, verificado uma vez por dia.
/// Em Debug o verificador fica parado, para o build de desenvolvimento não oferecer a release.
@MainActor final class Updates: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updates()

    private lazy var controller: SPUStandardUpdaterController = {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: self)
    }()

    func start() { _ = controller }

    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in Dogfood.shared.record("update.check", ["result": "offered", "offered": version]) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let info = (error as NSError).userInfo
        let reason = (info[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        let latest = (info[SPULatestAppcastItemFoundKey] as? SUAppcastItem)?.displayVersionString
        Task { @MainActor in
            Dogfood.shared.record("update.check", ["result": reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue ? "newerThanFeed" : "none",
                                                   "reason": reason.map { Int($0) }, "feed": latest])
        }
    }

    // App só de barra de menus: o aviso de nova versão aparece sem tomar o foco.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
