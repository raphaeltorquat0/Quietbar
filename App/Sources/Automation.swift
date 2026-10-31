import AppIntents
import MDRKit
import MDRSession
import Observation
import QuietAudio
import QuietAutomation

/// Liga o motor de prioridade ao mundo: detector de chamada, Filtros de Foco e o fone.
@MainActor @Observable
final class Automation {
    static let shared = Automation()

    let engine = AutomationEngine(device: AutomationBridge())
    /// O que o detector vê agora; a aba Automação usa para oferecer "Ignorar".
    private(set) var micUsage = MicUsage(deviceRunning: false, processes: [])

    @ObservationIgnored private let settings = AppSettings.shared
    @ObservationIgnored private let monitor = MicMonitor()
    @ObservationIgnored private var inCall = false
    @ObservationIgnored private var focusProfileID: UUID?
    @ObservationIgnored private var wasReady = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private lazy var debouncer = Debouncer(delay: .seconds(settings.callDelaySeconds)) { [weak self] active in
        self?.inCall = active
        self?.refreshCall()
    }

    /// Consulta do Foco quando o `perform` do filtro não chega. Há relato de que ele não é chamado no macOS 26.5.
    private static let focusPoll = Duration.seconds(30)

    func start() {
        guard !started else { return }
        started = true
        monitor.onChange = { Automation.shared.micChanged($0) }
        settingsChanged()
        Task {
            while true {
                await refreshFocus()
                try? await Task.sleep(for: Self.focusPoll)
            }
        }
    }

    /// Texto do indicador no menu. `nil` sem regra ativa.
    var indicator: String? {
        switch engine.active {
        case nil: nil
        case .manual: String(localized: "Ajuste manual")
        case .rule(.call, _): String(localized: "Em chamada")
        case .rule(.focus, let name): String(localized: "Foco: \(name)")
        case .rule(.app, let name): String(localized: "App: \(name)")
        case .rule(.wifi, let name): String(localized: "Wi-Fi: \(name)")
        }
    }

    /// Um gatilho, modo ou lista mudou nas Configurações.
    func settingsChanged() {
        if settings.callRuleEnabled {
            debouncer.delay = .seconds(settings.callDelaySeconds)
            monitor.start()
            micChanged(micUsage)
        } else {
            monitor.stop()
            debouncer.reset()
            inCall = false
            micUsage = MicUsage(deviceRunning: false, processes: [])
        }
        refreshCall()
        refreshFocusRule()
        ProfileEngine.shared.evaluate()
    }

    private func micChanged(_ usage: MicUsage) {
        micUsage = usage
        debouncer.input(usage.inCall(ignoring: Set(settings.micIgnoredApps.map(\.bundleID))))
    }

    private func refreshCall() {
        let on = inCall && settings.callRuleEnabled
        engine.set(.call, on ? Rule(id: "call", name: "Chamada", settings: [.soundMode: .mode(settings.callMode)]) : nil)
    }

    // MARK: - Foco

    /// Só o que o Filtro de Foco entrega, por API pública. Sair do Foco chega como perfil vazio.
    func focusChanged(_ id: UUID?) {
        focusProfileID = id
        refreshFocusRule()
    }

    func refreshFocusRule() {
        let profile = ProfileEngine.shared.profiles.first { $0.id == focusProfileID }
        var rule = profile.flatMap { settings.focusRuleEnabled ? $0.rule : nil }
        rule?.id = "focus:\(profile?.id.uuidString ?? "")"
        engine.set(.focus, rule)
    }

    private func refreshFocus() async {
        do {
            focusChanged(try await QuietbarFocusFilter.current.profile?.id)
        } catch SetFocusFilterIntentError.notFound {
            focusChanged(nil)
        } catch {} // o sistema não respondeu: fica o último valor conhecido
    }

    // MARK: - Fone

    /// Toda mudança do fone chega aqui. O que o motor não escreveu conta como ajuste manual.
    func report() {
        let device = DeviceController.shared
        let ready = device.isReady
        if ready, !wasReady { engine.deviceAvailable() }
        if !ready, wasReady { engine.deviceLost() }
        wasReady = ready
        engine.deviceReported((ready ? device.state.automationSettings : [:]).merging(MacSound.shared.automationSettings) { $1 })
    }

    /// "Aplicar perfil" dos Atalhos: conta como ajuste manual e vale até a próxima mudança de contexto.
    func apply(_ profile: Profile) {
        engine.applyManually(profile.settings)
    }
}

extension MDRDeviceState {
    var automationSettings: Settings {
        var s = Settings()
        s[.soundMode] = noiseControl.map { .mode($0.soundMode) }
        s[.ambientLevel] = noiseControl.map { .int(Int($0.ambientLevel)) }
        s[.focusOnVoice] = noiseControl.map { .bool($0.focusOnVoice) }
        s[.equalizerPreset] = equalizer.map { .int(Int($0.presetID)) }
        s[.speakToChat] = speakToChat.map { .bool($0) }
        return s
    }

    /// O `ready` chega com o ACK do último GET: as respostas podem vir um instante depois.
    fileprivate var loadedForAutomation: Bool {
        (capabilities.noiseControlType == nil || noiseControl != nil)
            && (capabilities.equalizerType == nil || equalizer != nil)
            && (!capabilities.speakToChat || speakToChat != nil)
    }
}

extension MacSound {
    /// Sem a permissão, o Som no Mac não existe para o motor: um perfil nunca liga a captura (DECISIONS.md #104).
    var automationSettings: Settings {
        canProcess ? [.macSound: .bool(enabled), .macPreset: .text(preset.rawValue)] : [:]
    }
}

/// O fone e o Som no Mac como o motor os enxerga.
@MainActor
private final class AutomationBridge: AutomationDevice {
    func read(headphone: Bool) async -> Settings? {
        var out = MacSound.shared.automationSettings
        guard headphone else { return out }
        let device = DeviceController.shared
        guard device.isBluetoothConnected else { return nil }
        let state = try? await device.run { session in
            for _ in 0..<20 {
                let state = await session.state
                if state.loadedForAutomation { return state }
                try await Task.sleep(for: .milliseconds(100))
            }
            return await session.state
        }
        guard let state else { return nil }
        out.merge(state.automationSettings) { $1 }
        return out
    }

    func write(_ changes: Settings) async throws -> Settings {
        var applied = changes
        let device = DeviceController.shared
        // Fone só com ambiente: o modo "cancelamento" não existe nele.
        if changes[.soundMode] == .mode(.noiseCanceling), device.state.noiseControl?.inquiredType == 0x22 {
            applied[.soundMode] = nil
        }
        let head = applied.filter(\.key.isHeadphone)
        if !head.isEmpty { try await device.run { try await head.apply(to: $0) } }
        let sound = MacSound.shared
        if case .bool(let on)? = applied[.macSound] { sound.apply(enabled: on, preset: nil) }
        if case .text(let preset)? = applied[.macPreset] { sound.apply(enabled: nil, preset: preset) }
        return applied
    }
}

private extension Settings {
    func apply(to s: MDRSession) async throws {
        var mode: SoundMode?, level: UInt8?, voice: Bool?, preset: UInt8?, chat: Bool?
        for (field, value) in self {
            switch (field, value) {
            case (.soundMode, .mode(let m)): mode = m
            case (.ambientLevel, .int(let v)): level = UInt8(clamping: v)
            case (.focusOnVoice, .bool(let v)): voice = v
            case (.equalizerPreset, .int(let v)): preset = UInt8(clamping: v)
            case (.speakToChat, .bool(let v)): chat = v
            default: break
            }
        }
        if mode != nil || level != nil || voice != nil {
            try await s.setNoiseControl { [mode, level, voice] n in
                if let mode { n.soundMode = mode }
                if let level { n.ambientLevel = level }
                if let voice { n.focusOnVoice = voice }
            }
        }
        if let preset { try await s.setEqualizerPreset(preset) }
        if let chat { try await s.setSpeakToChat(chat) }
    }
}
