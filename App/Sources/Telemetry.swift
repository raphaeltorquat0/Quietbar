import AppKit
import Foundation
import MDRKit
import QuietAutomation
import QuietTelemetry

/// Liga as métricas ao app. Só conta com o opt-in ligado, e só envia com `QuietbarTelemetryURL` no Info.plist.
@MainActor
final class Telemetry {
    static let shared = Telemetry()

    let recorder = TelemetryRecorder(
        load: { UserDefaults.standard.data(forKey: "telemetryState") },
        save: { UserDefaults.standard.set($0, forKey: "telemetryState") },
        context: { Telemetry.context() })
    let endpoint = TelemetryRecorder.endpoint(Bundle.main.object(forInfoDictionaryKey: "QuietbarTelemetryURL") as? String)

    private var tracker = ModeChangeTracker()
    private var started = false

    private static let tick = Duration.seconds(3600)
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral // sem cookies nem cache
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func start() {
        guard !started else { return }
        started = true
        Automation.shared.engine.onEvent = { Telemetry.shared.handle($0) }
        Task {
            while true {
                recorder.recordAppRunning()
                await send()
                try? await Task.sleep(for: Self.tick)
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            askOnce()
        }
    }

    private func send() async {
        await recorder.sendIfDue(endpoint: endpoint) { request in
            let (_, response) = try await Self.session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
    }

    // MARK: - Eventos

    /// Painel, atalho, Central de Controle ou intent pediram um modo. Conta só se o fone mudar.
    func modeRequested(_ source: ModeSource) { tracker.expect(.user(source), at: Date()) }

    func modeReported(_ mode: SoundMode?) {
        if let source = tracker.observe(mode?.rawValue, at: Date()) { recorder.recordModeChange(source) }
    }

    func panelOpened() { recorder.recordPanelOpen() }

    func profileAppliedByShortcut() { recorder.recordTrigger(.shortcut) }

    private func handle(_ event: AutomationEvent) {
        #if DEBUG
        HardwareTest.trace(event)
        #endif
        switch event.kind {
        case .ruleStarted:
            if let trigger = event.trigger.flatMap(AutomationTrigger.init(rawValue:)) { recorder.recordTrigger(trigger) }
        case .write where event.fields?["soundMode"] != nil:
            tracker.expect(.engine, at: Date())
        case .manual where event.rule == "manual" && event.trigger != "applyManually":
            recorder.recordOverride()
        default: break
        }
    }

    // MARK: - Pacote

    private static func context() -> TelemetryContext {
        let s = AppSettings.shared
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return TelemetryContext(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            arch: arch,
            deviceModelFamily: ModelFamily.normalize(DeviceController.shared.state.modelName),
            automationEnabled: s.callRuleEnabled || ProfileEngine.shared.profiles.contains { $0.enabled && $0.trigger != .none },
            trialDay: nil) // nulo durante o beta: não há período de teste (DECISIONS.md #145)
    }

    // MARK: - Pergunta

    /// Uma vez só. Sem endpoint a pergunta seria gasta à toa: nada sairia do Mac.
    private func askOnce() {
        let d = UserDefaults.standard
        guard endpoint != nil, !d.bool(forKey: "telemetryAsked") else { return }
        d.set(true, forKey: "telemetryAsked")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Compartilhar métricas anônimas de uso?")
        alert.informativeText = String(localized: "Para saber quais recursos são usados, o Quietbar pode enviar um resumo por dia: contadores, modelo do fone e versões. Nunca inclui nomes de fone, de rede, de app ou de Foco. Vem desligado, e você pode mudar em Ajustes › Privacidade.")
        alert.addButton(withTitle: String(localized: "Agora não")) // primeiro botão: o padrão do Return
        alert.addButton(withTitle: String(localized: "Ativar métricas"))
        alert.buttons[0].keyEquivalent = "\r"
        if alert.runModal() == .alertSecondButtonReturn { recorder.setEnabled(true) }
    }
}
