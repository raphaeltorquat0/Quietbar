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

    /// Permissão de gravar o áudio do sistema. Só o botão do onboarding a pede.
    private(set) var permission = SystemPermission.Status.notAsked
    /// O diálogo do macOS está aberto, até onde o app sabe.
    private(set) var asking = false
    /// Resultado do último clique no botão de pedir a permissão.
    private(set) var askMessage: String?
    /// O que o usuário escolheu. A tap só sobe se a permissão também existir: sem ela, montar faria o
    /// próprio `coreaudiod` abrir o diálogo, sem clique nenhum.
    var enabled: Bool {
        didSet {
            d.set(enabled, forKey: "macSoundEnabled")
            syncEngine()
        }
    }
    var isOn: Bool { enabled && permission == .granted }

    /// Consentimento para procurar o `ParametricEQ.txt` em ~/Downloads.
    var watchConsent: Bool {
        didSet {
            d.set(watchConsent, forKey: "macSoundWatchConsent")
            if !watchConsent { stopWatching() }
        }
    }
    private(set) var watching = false
    private(set) var foundCurve: EQCurve?
    @ObservationIgnored private var watcher: CurveDownloadWatcher?
    @ObservationIgnored private var watchTimer: Timer?
    private static let watchSeconds = 15 * 60.0
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
        d.register(defaults: ["macSoundEnabled": false, "macSoundWatchConsent": false])
        enabled = d.bool(forKey: "macSoundEnabled")
        watchConsent = d.bool(forKey: "macSoundWatchConsent")
        preset = d.string(forKey: "macSoundPreset").flatMap(MacPreset.init) ?? .flat
        correction = AppSettings.load("macSoundCorrection")
        custom = AppSettings.load("macSoundCustom") ?? EQCurve(name: MacPreset.custom.label, filters: [])
        if #available(macOS 14.2, *) {
            let chain = DSPChain()
            engine = AudioEngine(backend: CoreAudioBackend(chain: chain), chain: chain)
        } else {
            engine = nil // sem process taps
        }
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
        Task {
            let status = await Task.detached { SystemPermission.status(.audioCapture) }.value
            permission = status
            syncEngine()
        }
    }

    /// Ligar sem a permissão passa pelo onboarding, em Configurações.
    func toggle() {
        if permission == .granted { enabled.toggle() } else { StatusBar.openSettingsWindow(tab: "macsound") }
    }

    /// Único caminho que abre o diálogo: chamado pelo botão do onboarding. Sem resposta, não tenta de novo.
    func requestPermission() {
        guard !asking else { return }
        askMessage = nil
        Task {
            let playing = await Task.detached { AudioDevices.playingApps() }.value
            guard let playing, playing.isEmpty else {
                let apps = (playing ?? []).map { $0.split(separator: ".").last.map(String.init) ?? $0 }.joined(separator: ", ")
                askMessage = String(localized: "Pause o áudio antes de continuar.") + (apps.isEmpty ? "" : " " + String(localized: "Ainda tocando: \(apps)."))
                return
            }
            asking = true
            SystemPermission.request(.audioCapture) { granted in
                Task { @MainActor in MacSound.shared.answered(granted) }
            }
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

    // MARK: Curva de correção

    /// Espera o arquivo por 15 minutos depois do clique. Consulta só esses nomes (`CurveDownloadWatcher`).
    func startWatching() {
        guard watchConsent, let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        stopWatching()
        watcher = CurveDownloadWatcher(directory: downloads)
        watching = true
        let deadline = Date().addingTimeInterval(Self.watchSeconds)
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { MacSound.shared.pollDownloads(deadline) }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        watcher = nil
        watching = false
    }

    private func pollDownloads(_ deadline: Date) {
        if Date() > deadline { return stopWatching() }
        guard let found = watcher?.poll() else { return }
        stopWatching()
        foundCurve = found.curve
        Notifier.post(title: String(localized: "Curva de correção encontrada"),
                      body: String(localized: "Abra Som no Mac nas Configurações para importar."))
    }

    func acceptFoundCurve() {
        guard let foundCurve else { return }
        correction = foundCurve
        preset = .correction
        self.foundCurve = nil
        if permission == .granted { enabled = true }
    }

    func dismissFoundCurve() { foundCurve = nil }

    /// Editar um preset pronto salva como "Personalizada".
    func edit(_ change: (inout EQCurve) -> Void) {
        var c = curve
        c.name = MacPreset.custom.label
        change(&c)
        custom = c
        preset = .custom
    }

    func apply(enabled on: Bool?, preset p: String?) {
        guard permission == .granted else { return } // perfil nunca chega perto do pedido de permissão
        if let p = p.flatMap(MacPreset.init), p != .correction || correction != nil { preset = p }
        if let on { enabled = on }
    }

    var statusText: String {
        guard let engine else { return String(localized: "Exige macOS 14.2 ou mais novo.") }
        if enabled, permission != .granted { return String(localized: "Precisa da permissão") }
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
