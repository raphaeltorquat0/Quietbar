import Foundation
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
    @ObservationIgnored private var focusPollWorks = false
    @ObservationIgnored private var wasReady = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private lazy var debouncer = Debouncer(delay: .seconds(settings.callDelaySeconds)) { [weak self] active in
        self?.inCall = active
        Dogfood.shared.callChanged(active, apps: self?.micUsage.processes)
        #if DEBUG
        HardwareTest.trace(call: active)
        #endif
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
    var indicator: String? { Self.label(for: engine.active) }

    static func label(for rule: ActiveRule?) -> String? {
        switch rule {
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
            Dogfood.shared.callChanged(false, apps: nil)
            micUsage = MicUsage(deviceRunning: false, processes: [])
        }
        refreshCall()
        refreshFocusRule()
        ProfileEngine.shared.evaluate()
    }

    private func micChanged(_ usage: MicUsage) {
        micUsage = usage
        engine.noteTrigger("mic", detail: "running=\(usage.deviceRunning) processes=\(usage.processes?.count ?? -1)")
        #if DEBUG
        HardwareTest.trace(mic: usage)
        #endif
        debouncer.input(usage.inCall(ignoring: Set(settings.micIgnoredApps.map(\.bundleID))))
    }

    private func refreshCall() {
        let on = inCall && settings.callRuleEnabled
        engine.set(.call, on ? Rule(id: "call", name: "Chamada", settings: [.soundMode: .mode(settings.callMode)]) : nil)
    }

    // MARK: - Foco

    /// Só o que o Filtro de Foco entrega, por API pública. Sair do Foco chega como perfil vazio.
    func focusChanged(_ id: UUID?, source: String = "focus.perform") {
        if id != focusProfileID {
            engine.noteTrigger(source, detail: id == nil ? "off" : "on")
            Dogfood.shared.record("focus.change", ["active": id != nil, "profile": ProfileEngine.shared.profiles.first { $0.id == id }?.name])
        }
        focusProfileID = id
        refreshFocusRule()
    }

    func refreshFocusRule() {
        let profile = ProfileEngine.shared.profiles.first { $0.id == focusProfileID }
        var rule = profile.flatMap { settings.focusRuleEnabled ? $0.rule : nil }
        rule?.id = "focus:\(profile?.id.uuidString ?? "")"
        engine.set(.focus, rule)
    }

    /// Vazio só vale depois de `current` já ter devolvido um perfil: se ele não funcionar neste sistema,
    /// uma consulta vazia não pode apagar o que o `perform` entregou.
    private func refreshFocus() async {
        let id = (try? await QuietbarFocusFilter.current)?.profile?.id
        if id != nil { focusPollWorks = true }
        if id != nil || focusPollWorks { focusChanged(id, source: "focus.poll") }
    }

    // MARK: - Fone

    /// Toda mudança do fone chega aqui. O que o motor não escreveu conta como ajuste manual.
    func report() {
        let device = DeviceController.shared
        let ready = device.isReady
        if ready, !wasReady { engine.deviceAvailable() }
        wasReady = ready
        engine.deviceReported((ready ? device.state.automationSettings : [:]).merging(MacSound.shared.automationSettings) { $1 })
    }

    /// "Aplicar perfil" dos Atalhos: conta como ajuste manual e vale até a próxima mudança de contexto.
    func apply(_ profile: Profile) {
        engine.applyManually(profile.settings)
        Telemetry.shared.profileAppliedByShortcut()
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
final class AutomationBridge: AutomationDevice {
    #if DEBUG
    /// Validação: o fone some, como no instante depois de acordar o Mac.
    static var simulateUnavailable = false
    /// Validação: o fone não informa o modo depois de reabrir o canal.
    static var simulateNoModeReply = false
    #endif

    /// Por endereço do fone. Num fone simulado o endereço é o do real selecionado: só em Debug.
    var heldMode: SoundMode? {
        get {
            guard let address = DeviceController.shared.selectedAddress else { return nil }
            return (UserDefaults.standard.dictionary(forKey: Self.heldModesKey)?[address] as? String).flatMap(SoundMode.init(rawValue:))
        }
        set {
            guard let address = DeviceController.shared.selectedAddress else { return }
            var all = UserDefaults.standard.dictionary(forKey: Self.heldModesKey) ?? [:]
            all[address] = newValue?.rawValue
            UserDefaults.standard.set(all, forKey: Self.heldModesKey)
        }
    }

    private static let heldModesKey = "automationHeldModes"

    func read(headphone: Bool) async -> DeviceReading? {
        var out = MacSound.shared.automationSettings
        guard headphone else { return DeviceReading(settings: out, check: .notNeeded) }
        let device = DeviceController.shared
        #if DEBUG
        if Self.simulateUnavailable { return nil }
        #endif
        guard device.isBluetoothConnected else { return nil }
        let reopened = !device.isReady
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
        #if DEBUG
        if Self.simulateNoModeReply, reopened { out[.soundMode] = nil }
        #endif
        // A sessão zera o estado ao abrir o canal e refaz os GET: com o canal solto, o modo acima veio do fone agora.
        let unread = state.capabilities.noiseControlType != nil && out[.soundMode] == nil
        return DeviceReading(settings: out, check: unread ? .failed : reopened ? .fresh : .notNeeded)
    }

    func write(_ changes: Settings) async throws -> Settings {
        let device = DeviceController.shared
        var applied = changes
        let wanted = changes.filter(\.key.isHeadphone)
        if !wanted.isEmpty {
            // Dentro da fila: é o estado na hora do envio, depois de qualquer ação que estava na frente.
            let sent = try await device.run { s -> QuietAutomation.Settings in
                let state = await s.state
                var send = wanted.filter { state.automationSettings[$0.key] != $0.value }
                // Fone só com ambiente: o modo "cancelamento" não existe nele.
                if send[.soundMode] == .mode(.noiseCanceling), state.noiseControl?.inquiredType == 0x22 { send[.soundMode] = nil }
                if !send.isEmpty { try await send.apply(to: s) }
                return send
            }
            for field in wanted.keys where sent[field] == nil { applied[field] = nil }
        }
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
