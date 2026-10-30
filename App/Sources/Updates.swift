import AppKit
import Sparkle

/// Atualizações pelo Sparkle: `docs/appcast.xml` no GitHub Pages, verificado uma vez por dia.
/// Em Debug o verificador fica parado, para o build de desenvolvimento não oferecer a release.
@MainActor final class Updates: NSObject, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    private lazy var controller: SPUStandardUpdaterController = {
        #if DEBUG
        let start = false
        #else
        let start = true
        #endif
        return SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: self)
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

    // App só de barra de menus: o aviso de nova versão aparece sem tomar o foco.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
