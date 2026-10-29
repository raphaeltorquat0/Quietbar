import Foundation

/// O Control da Central de Controle (extensão `QuietbarControls`, macOS 26+) roda em outro processo,
/// sem o canal RFCOMM. Ele só posta esta notificação Darwin; o app, dono da sessão, executa a ação.
enum ControlCenterBridge {
    static let toggleSoundMode = "io.github.raphaeltorquat0.quietbar.toggleSoundMode"

    static func start() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ShortcutAction.toggleNcAmbient.run(DeviceController.shared) }
            }
        }, toggleSoundMode as CFString, nil, .deliverImmediately)
    }
}
