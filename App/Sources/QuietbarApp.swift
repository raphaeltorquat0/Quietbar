import HeadphoneModel
import MDRKit
import ServiceManagement
import SwiftUI

@main
struct QuietbarApp: App {
    @State private var device = DeviceController.shared

    init() {
        if CommandLine.arguments.contains("--selftest") { Self.selfTest() }
        if let i = CommandLine.arguments.firstIndex(of: "--render-panel-previews") {
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "/tmp/quietbar-ui"
            Task { @MainActor in PanelPreviewRenderer.run(to: URL(fileURLWithPath: dir)) }
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--press-kit") {
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "/tmp/quietbar-press-kit"
            Task { @MainActor in await PressKit.run(to: URL(fileURLWithPath: dir)) }
            return
        }
        #endif
        // `make install` abre o app com esta flag: só o próprio app pode se registrar como item de login.
        if CommandLine.arguments.contains("--register-login-item") { try? SMAppService.mainApp.register() }
        HotKeys.shared.register()
        ProfileEngine.shared.start()
        PopupController.shared.start()
        Self.prewarm3D()
        StatusBar.shared.install()
        Updates.shared.start()
        DemoPanel.openIfRequested()
        #if DEBUG
        Simulation.shared.startIfRequested()
        #endif
        ControlCenterBridge.start()
    }

    /// Gera IBL e protótipo do modelo em segundo plano (≈ 1 s, uma vez), para o painel abrir na hora.
    private static func prewarm3D() {
        guard #available(macOS 15, *) else { return }
        var spec = HeadphoneSpec.default
        spec.lightRing = AppSettings.shared.modelLightRing
        Task(priority: .utility) { @MainActor in await HeadphoneRealityKit.prewarm(spec) }
    }

    /// `Quietbar.app/Contents/MacOS/Quietbar --selftest`: abre o canal com o fone, imprime e sai.
    /// Serve para validar o RFCOMM com e sem App Sandbox sem precisar da UI.
    private static func selfTest() {
        Task { @MainActor in
            let c = DeviceController.shared
            await c.ensureConnected()
            try? await Task.sleep(for: .seconds(1))
            print("phase=\(c.snapshot.phase) model=\(c.state.modelName ?? "-") fw=\(c.state.firmwareVersion ?? "-") error=\(c.lastError ?? "-")")
            exit(c.isReady ? 0 : 1)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView().environment(device)
        }
    }
}
