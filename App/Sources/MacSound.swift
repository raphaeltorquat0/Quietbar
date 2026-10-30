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

    /// O usuário já viu a explicação da permissão.
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "macSoundOnboarded") } }
    var enabled: Bool {
        didSet {
            d.set(enabled, forKey: "macSoundEnabled")
            engine?.setEnabled(enabled)
        }
    }
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
        d.register(defaults: ["macSoundEnabled": false, "macSoundOnboarded": false])
        onboarded = d.bool(forKey: "macSoundOnboarded")
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
    }

    func start() {
        engine?.setCurve(curve)
        engine?.setTarget(address: DeviceController.shared.selectedAddress)
        engine?.setEnabled(enabled)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacSound.shared.engine?.refreshOutput() }
        }
    }

    func targetChanged(_ address: String?) { engine?.setTarget(address: address) }

    /// Ligar pela primeira vez passa pela explicação da permissão, em Configurações.
    func toggle() {
        if onboarded { enabled.toggle() } else { StatusBar.openSettingsWindow(tab: "macsound") }
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
        guard onboarded else { return } // perfil nunca liga a captura antes do consentimento
        if let p = p.flatMap(MacPreset.init), p != .correction || correction != nil { preset = p }
        if let on { enabled = on }
    }

    var statusText: String {
        guard let engine else { return String(localized: "Exige macOS 14.2 ou mais novo.") }
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
