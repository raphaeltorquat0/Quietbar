import AppIntents
import MDRKit
import MDRSession

// Os intents ficam no alvo do app, não num pacote: é aqui que o Xcode extrai os metadados que o sistema lê.
// Rodam no processo do app, dono do canal com o fone; o sistema abre o app em segundo plano se preciso.

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notConnected, noBattery, invalidLevel, presetNotOnDevice, profileGone

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "O fone não está conectado ao Mac."
        case .noBattery: "O fone não informou a bateria."
        case .invalidLevel: "O nível do ambiente vai de 1 a 20."
        case .presetNotOnDevice: "Este fone não tem esse preset."
        case .profileGone: "Esse perfil não existe mais."
        }
    }
}

/// Passa pela fila única do `DeviceController`. O motor vê a mudança no fone e a trata como ajuste manual.
@MainActor
private func onHeadphone<T: Sendable>(_ action: @escaping @Sendable (MDRSession) async throws -> T) async throws -> T {
    do { return try await DeviceController.shared.run(action) } catch is NotConnected { throw IntentFailure.notConnected }
}

// MARK: - Entidades

enum NoiseModeOption: String, AppEnum {
    case noiseCanceling, ambient, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Modo de ruído"
    static let caseDisplayRepresentations: [NoiseModeOption: DisplayRepresentation] = [
        .noiseCanceling: "Cancelamento de ruído",
        .ambient: "Som ambiente",
        .off: "Desligado",
    ]

    var mode: SoundMode {
        switch self {
        case .noiseCanceling: .noiseCanceling
        case .ambient: .ambient
        case .off: .off
        }
    }
}

struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Perfil do Quietbar"
    static let defaultQuery = ProfileQuery()

    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ profile: Profile) {
        id = profile.id
        name = profile.name
    }
}

struct ProfileQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        ProfileEngine.shared.profiles.filter { identifiers.contains($0.id) }.map(ProfileEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ProfileEntity] {
        ProfileEngine.shared.profiles.map(ProfileEntity.init)
    }
}

struct EqPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset de EQ"
    static let defaultQuery = EqPresetQuery()

    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    @MainActor init(id: UInt8) {
        self.id = Int(id)
        name = PresetNames.name(id, custom: AppSettings.shared.presetNames)
    }
}

struct EqPresetQuery: EntityQuery {
    /// Com o fone desconectado, oferece os presets conhecidos; o `perform` confere no fone.
    @MainActor private func all() -> [EqPresetEntity] {
        let onDevice = DeviceController.shared.state.equalizerPresets.map(\.id)
        return (onDevice.isEmpty ? EqPreset.knownNames.keys.sorted() : onDevice).map(EqPresetEntity.init(id:))
    }

    @MainActor func entities(for identifiers: [Int]) async throws -> [EqPresetEntity] {
        identifiers.compactMap(UInt8.init(exactly:)).map(EqPresetEntity.init(id:))
    }

    @MainActor func suggestedEntities() async throws -> [EqPresetEntity] { all() }
}

// MARK: - Foco

/// Filtro de Foco: o perfil é escolhido em Ajustes do Sistema › Foco. É a única forma pública de saber
/// o Foco atual; ao sair dele, o `perform` chega com o perfil vazio.
struct QuietbarFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Perfil do Quietbar"
    static let description: IntentDescription? = "Aplica um perfil do Quietbar enquanto este Foco estiver ativo."

    @Parameter(title: "Perfil") var profile: ProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(profile?.name ?? String(localized: "Nenhum perfil"))")
    }

    @MainActor func perform() async throws -> some IntentResult {
        Automation.shared.focusChanged(profile?.id)
        return .result()
    }
}

// MARK: - Atalhos

struct SetNoiseModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Definir modo de ruído"
    static let description: IntentDescription? = "Muda o fone para cancelamento de ruído, som ambiente ou desligado."
    static var parameterSummary: some ParameterSummary { Summary("Definir modo de ruído como \(\.$mode)") }

    @Parameter(title: "Modo") var mode: NoiseModeOption

    @MainActor func perform() async throws -> some IntentResult {
        let mode = mode.mode
        Telemetry.shared.modeRequested(.intent)
        try await onHeadphone { try await $0.setSoundMode(mode) }
        return .result()
    }
}

struct SetAmbientLevelIntent: AppIntent {
    static let title: LocalizedStringResource = "Definir nível do ambiente"
    static let description: IntentDescription? = "Ajusta o nível do som ambiente, de 1 a 20."
    static var parameterSummary: some ParameterSummary { Summary("Definir nível do ambiente como \(\.$level)") }

    @Parameter(title: "Nível", inclusiveRange: (1, 20)) var level: Int

    @MainActor func perform() async throws -> some IntentResult {
        guard (1...20).contains(level) else { throw IntentFailure.invalidLevel }
        let level = level
        try await onHeadphone { try await $0.setAmbientLevel(level) }
        return .result()
    }
}

struct ApplyProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Aplicar perfil"
    static let description: IntentDescription? = "Aplica um perfil do Quietbar até a próxima mudança de contexto."
    static var parameterSummary: some ParameterSummary { Summary("Aplicar \(\.$profile)") }

    @Parameter(title: "Perfil") var profile: ProfileEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let p = ProfileEngine.shared.profiles.first(where: { $0.id == profile.id }) else { throw IntentFailure.profileGone }
        if p.settings.keys.contains(where: { $0.isHeadphone }), !DeviceController.shared.isBluetoothConnected {
            throw IntentFailure.notConnected
        }
        Automation.shared.apply(p)
        return .result()
    }
}

struct ApplyEqPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Aplicar preset de EQ"
    static let description: IntentDescription? = "Aplica um preset do equalizador do fone."
    static var parameterSummary: some ParameterSummary { Summary("Aplicar preset \(\.$preset)") }

    @Parameter(title: "Preset") var preset: EqPresetEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let id = UInt8(exactly: preset.id) else { throw IntentFailure.presetNotOnDevice }
        let known = try await onHeadphone { s in
            let presets = await s.state.equalizerPresets
            if presets.isEmpty || presets.contains(where: { $0.id == id }) {
                try await s.setEqualizerPreset(id)
                return true
            }
            return false
        }
        guard known else { throw IntentFailure.presetNotOnDevice }
        return .result()
    }
}

struct GetBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Consultar bateria do fone"
    static let description: IntentDescription? = "Devolve a bateria do fone, em porcentagem. Em earbuds, a do lado mais fraco."

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let level = try await onHeadphone { s -> Int? in
            for _ in 0..<20 { // a resposta pode chegar um instante depois de o canal abrir
                if let b = await s.state.primaryBattery { return Int(b.level) }
                try await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        guard let level else { throw IntentFailure.noBattery }
        return .result(value: level, dialog: "Bateria em \(level)%.")
    }
}

struct QuietbarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SetNoiseModeIntent(), phrases: [
            "Definir o \(.applicationName) como \(\.$mode)",
            "Mudar o modo de ruído no \(.applicationName)",
        ], shortTitle: "Modo de ruído", systemImageName: "headphones")
        AppShortcut(intent: SetAmbientLevelIntent(), phrases: [
            "Ajustar o som ambiente no \(.applicationName)",
        ], shortTitle: "Nível do ambiente", systemImageName: "ear")
        AppShortcut(intent: ApplyProfileIntent(), phrases: [
            "Aplicar \(\.$profile) no \(.applicationName)",
            "Aplicar um perfil no \(.applicationName)",
        ], shortTitle: "Aplicar perfil", systemImageName: "person.crop.rectangle.stack")
        AppShortcut(intent: ApplyEqPresetIntent(), phrases: [
            "Aplicar um preset de equalizador no \(.applicationName)",
        ], shortTitle: "Preset de EQ", systemImageName: "slider.vertical.3")
        AppShortcut(intent: GetBatteryIntent(), phrases: [
            "Qual a bateria no \(.applicationName)",
            "Consultar a bateria no \(.applicationName)",
        ], shortTitle: "Bateria do fone", systemImageName: "battery.75percent")
    }
}
