import AppKit
import Observation
import QuietAudio

/// Presets do Som no Mac. "Correção" é sempre uma curva que o usuário importou (DECISIONS.md #95).
enum MacPreset: String, Codable, CaseIterable, Identifiable {
    case correction, bass, voice, flat, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .correction: String(localized: "Correção")
        case .bass: String(localized: "Mais grave")
        case .voice: String(localized: "Voz")
        case .flat: String(localized: "Plano")
        case .custom: String(localized: "Personalizada")
        }
    }

    var builtIn: EQCurve? {
        switch self {
        case .bass: EQCurve(name: label, filters: [EQFilter(.lowShelf, frequency: 105, gain: 5, q: 0.7)])
        case .voice: EQCurve(name: label, filters: [EQFilter(.lowShelf, frequency: 150, gain: -3, q: 0.7),
                                                    EQFilter(.peak, frequency: 2500, gain: 3, q: 1)])
        case .flat: EQCurve(name: label, filters: [])
        case .correction, .custom: nil
        }
    }
}

/// Som no Mac: preferências, curva escolhida e o motor de áudio. `engine` é nil antes do macOS 14.2.
@MainActor @Observable
final class MacSound {
    static let shared = MacSound()

    let engine: AudioEngine?
    @ObservationIgnored private let d = UserDefaults.standard

    @ObservationIgnored let permissions: SystemPermission = {
        #if DEBUG
        if CommandLine.arguments.contains("--no-tcc-symbols") { return SystemPermission(lookup: { _ in nil }) }
        #endif
        return .live
    }()
    @ObservationIgnored private var loggedProblem: String?

    /// Permissão de gravar o áudio do sistema. Só o botão do onboarding a pede.
    private(set) var permission = SystemPermission.Status.notAsked
    /// O diálogo do macOS está aberto, até onde o app sabe.
    private(set) var asking = false
    /// Resultado do último clique no botão de pedir a permissão.
    private(set) var askMessage: String?
    /// Sem os símbolos do TCC, o usuário clicou para ligar e deixar o macOS pedir. Vale só nesta execução:
    /// gravado, um update ad-hoc abriria o diálogo ao iniciar, sem clique (DECISIONS.md #112).
    private(set) var systemFlowAccepted = false
    /// O que o usuário escolheu. A tap só sobe se a permissão também existir: sem ela, montar faria o
    /// próprio `coreaudiod` abrir o diálogo, sem clique nenhum.
    var enabled: Bool {
        didSet {
            d.set(enabled, forKey: "macSoundEnabled")
            syncEngine()
        }
    }
    var canProcess: Bool { permission == .granted || (permission == .unavailable && systemFlowAccepted) }
    var isOn: Bool { enabled && canProcess }

    /// A página da curva foi aberta: a aba passa a oferecer o import.
    var curvePageOpened = false
    private static let askTimeout = Duration.seconds(120)
    var preset: MacPreset {
        didSet {
            d.set(preset.rawValue, forKey: "macSoundPreset")
            engine?.setCurve(curve)
        }
    }
    /// Curva importada; é o que o preset "Correção" toca.
    var correction: EQCurve? {
        didSet {
            AppSettings.shared.save(correction, "macSoundCorrection")
            engine?.setCurve(curve)
        }
    }
    var custom: EQCurve {
        didSet {
            AppSettings.shared.save(custom, "macSoundCustom")
            engine?.setCurve(curve)
        }
    }

    var available: Bool { engine != nil }
    var outputIsHeadphone: Bool { engine?.outputIsTarget ?? false }

    var curve: EQCurve {
        switch preset {
        case .correction: correction ?? EQCurve(name: preset.label, filters: [])
        case .custom: custom
        default: preset.builtIn ?? EQCurve(name: "", filters: [])
        }
    }

    private init() {
        // Desligado em instalações novas e em updates: a 1.3.0 não tinha esta chave (DECISIONS.md #109).
        d.register(defaults: ["macSoundEnabled": false])
        enabled = d.bool(forKey: "macSoundEnabled")
        preset = d.string(forKey: "macSoundPreset").flatMap(MacPreset.init) ?? .flat
        correction = AppSettings.load("macSoundCorrection")
        custom = AppSettings.load("macSoundCustom") ?? EQCurve(name: MacPreset.custom.label, filters: [])
        if #available(macOS 14.2, *) {
            let chain = DSPChain()
            engine = AudioEngine(backend: CoreAudioBackend(chain: chain), chain: chain)
        } else {
            engine = nil // sem process taps
        }
        #if DEBUG
        if CommandLine.arguments.contains("--demo-curve-import") { curvePageOpened = true } // sem abrir a página no navegador
        #endif
    }

    func start() {
        engine?.setCurve(curve)
        engine?.setTarget(address: DeviceController.shared.selectedAddress)
        refreshPermission()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacSound.shared.engine?.refreshOutput() }
        }
    }

    func targetChanged(_ address: String?) { engine?.setTarget(address: address) }

    private func syncEngine() { engine?.setEnabled(isOn) }

    /// Só consulta. Em build ad-hoc, um update é outra identidade para o macOS: a permissão some e a
    /// tap fica desligada até o usuário clicar no botão de novo.
    func refreshPermission() {
        guard available else { return }
        let permissions = permissions
        Task {
            let status = await Task.detached { permissions.status(.audioCapture) }.value
            permission = status
            logPermissionProblem()
            syncEngine()
        }
    }

    private func logPermissionProblem() {
        guard let problem = permissions.problem, problem != loggedProblem else { return }
        loggedProblem = problem
        ProtocolLog.shared.note("Som no Mac: \(problem). O Quietbar passa a usar o fluxo padrão do macOS.")
    }

    /// Ligar sem a permissão passa pelo onboarding, em Configurações.
    func toggle() {
        if canProcess { enabled.toggle() } else { StatusBar.openSettingsWindow(tab: "macsound") }
    }

    /// Único caminho que abre o diálogo: chamado pelo botão do onboarding. Sem resposta, não tenta de novo.
    func requestPermission() {
        guard !asking else { return }
        askMessage = nil
        guard permission != .unavailable else {
            systemFlowAccepted = true
            ProtocolLog.shared.note("Som no Mac: ligado pelo fluxo padrão do macOS, a pedido do usuário.")
            enabled = true
            return syncEngine()
        }
        asking = true
        permissions.request(.audioCapture) { granted in
            Task { @MainActor in MacSound.shared.answered(granted) }
        }
        Task {
            try? await Task.sleep(for: Self.askTimeout)
            if asking {
                asking = false
                askMessage = String(localized: "Sem resposta ao pedido. O Quietbar não vai pedir de novo sozinho.")
            }
        }
    }

    private func answered(_ granted: Bool) {
        asking = false
        askMessage = granted ? nil : String(localized: "Permissão negada. Para mudar, vá a Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema.")
        permission = granted ? .granted : .denied
        if granted { enabled = true } else { syncEngine() }
    }

    /// Editar um preset pronto salva como "Personalizada".
    func edit(_ change: (inout EQCurve) -> Void) {
        var c = curve
        c.name = MacPreset.custom.label
        change(&c)
        custom = c
        preset = .custom
    }

    func apply(enabled on: Bool?, preset p: String?) {
        guard canProcess else { return } // perfil nunca chega perto do pedido de permissão
        if let p = p.flatMap(MacPreset.init), p != .correction || correction != nil { preset = p }
        if let on { enabled = on }
    }

    var statusText: String {
        guard let engine else { return String(localized: "Exige macOS 14.2 ou mais novo.") }
        if enabled, !canProcess { return String(localized: "Precisa da permissão") }
        switch engine.phase {
        case .off: return String(localized: "Desligado")
        case .waitingForOutput: return String(localized: "Só atua quando o fone é a saída do Mac")
        case .callMode: return String(localized: "Pausado durante chamadas")
        case .arming: return String(localized: "Aguardando áudio")
        case .active: return String(localized: "Ativo")
        case .failed: return String(localized: "Sem processamento: o áudio segue normal")
        }
    }
}
