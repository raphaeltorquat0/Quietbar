import MDRKit

/// Fone simulado: identidade, o que ele expõe e de onde cada dado veio.
public struct DeviceProfile: Identifiable, Sendable {
    public struct Citation: Sendable {
        public let project: String
        public let file: String
        public let license: String

        public static func libmdr(_ doc: String) -> Citation {
            Citation(project: "SonyHeadphonesClient (commit 68dfced)", file: "docs/device-support/\(doc).md", license: "MIT")
        }

        /// Licença AGPL: só a lista de recursos do modelo foi lida, como fato. Nenhum código foi copiado.
        public static func gadgetbridge(_ coordinator: String) -> Citation {
            Citation(project: "Gadgetbridge (commit edbea98)", file: "devices/sony/headphones/coordinators/\(coordinator).java", license: "AGPL, só como fato")
        }
    }

    public enum Origin: Sendable {
        /// Frames reais, já sanitizados, em `Tests/Fixtures`.
        case capture(fixtures: [String], source: String)
        /// Sem captura: recursos vindos de documentação. Os bytes saem do codificador do MDRKit.
        case reference([Citation])
    }

    public enum Battery: Sendable {
        case single
        case earbuds(hasCase: Bool)
    }

    public enum Sound: Sendable {
        case none
        /// Cancelamento de ruído e ambiente: tipo `0x17`.
        case noiseCanceling
        /// Só ambiente: tipo `0x22`.
        case ambientOnly
    }

    public enum Equalizer: Sendable {
        case none
        case clearBassFiveBands
        case tenBands
    }

    /// Ajuste geral (`0xD1`…`0xD4`) com o assunto que o fone informa.
    public struct GeneralSetting: Sendable {
        public let inquiredType: UInt8
        public let subject: String
    }

    public struct Features: Sendable {
        public var battery = Battery.single
        public var sound = Sound.none
        public var equalizer = Equalizer.none
        public var codec = true
        public var playback = true
        public var powerOff = true
        public var dsee = false
        public var speakToChat = false
        public var autoPause = false
        public var autoPowerOff = false
        public var ncAmbButton = false
        public var connectionPriority = false
        public var generalSettings: [GeneralSetting] = []

        public init() {}
    }

    public let id: String
    public let modelName: String
    public var firmware: String?
    public var series: UInt8?
    public var protocolVersion: UInt32?
    public var hasTable2 = true
    public var features: Features
    public let origin: Origin
    /// O que não veio de nenhuma fonte. Tudo aqui é aproximação do simulador.
    public var gaps: [String]

    public var isCapture: Bool { if case .capture = origin { true } else { false } }

    /// Funções anunciadas, derivadas dos recursos. Os códigos vêm de `docs/PROTOCOL.md` §3.3.
    var derivedFunctions: [UInt8] {
        let f = features
        var c: [UInt8] = []
        if f.codec { c.append(0x12) }
        switch f.battery {
        case .single: c.append(0x20)
        case .earbuds(let hasCase): c += hasCase ? [0x29, 0x2A] : [0x29]
        }
        if f.powerOff { c.append(0x23) }
        if f.autoPowerOff { c.append(0x25) }
        switch f.sound {
        case .none: break
        case .noiseCanceling: c.append(0x6B)
        case .ambientOnly: c.append(0x67)
        }
        if f.ncAmbButton { c.append(0x69) }
        if f.equalizer != .none { c.append(0x50) }
        if f.playback { c.append(0xA1) }
        c += f.generalSettings.map(\.inquiredType)
        if !f.generalSettings.isEmpty { c.append(0x90) }
        if f.connectionPriority { c.append(0xE1) }
        if f.dsee { c.append(0xE2) }
        if f.autoPause { c.append(0xF1) }
        if f.speakToChat { c.append(0xFC) }
        return c
    }

    /// Respostas iniciais a partir dos recursos, codificadas pelo MDRKit.
    var derivedResponses: [MDRMessage] {
        let f = features
        var m: [MDRMessage] = [
            .protocolInfo(version: protocolVersion ?? 0x0300_0000, table1: true, table2: hasTable2),
            .capabilityInfo(counter: 1, uniqueID: "02:00:00:00:00:01"),
            .firmwareVersion(firmware ?? "0.0.0"),
            .modelName(modelName),
            .seriesAndColor(series: series ?? 0, color: 0),
        ]
        if f.codec { m.append(.codec(.aac)) }
        switch f.battery {
        case .single:
            m.append(.battery(BatteryStatus(level: 80)))
        case .earbuds(let hasCase):
            m.append(.batteryLR(EarbudsBattery(left: BatteryStatus(level: 80, threshold: 100), right: BatteryStatus(level: 78, threshold: 100))))
            if hasCase { m.append(.batteryCase(BatteryStatus(level: 60, threshold: 30))) }
        }
        if f.autoPowerOff {
            m.append(.autoPowerOff(AutoPowerOff(wearingDetection: true, current: 0x10)))
            m.append(.autoPowerOffOptions(wearingDetection: true, [0x10, 0x11]))
        }
        switch f.sound {
        case .none: break
        case .noiseCanceling:
            m.append(.noiseControl(NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: false, ambientLevel: 12)))
        case .ambientOnly:
            m.append(.noiseControl(NoiseControl(inquiredType: 0x22, enabled: true, ambientMode: true, ambientLevel: 10)))
        }
        if f.ncAmbButton { m.append(.ncAmbButton(NcAmbButtonFunction(rawValue: 0x02))) }
        switch f.equalizer {
        case .none: break
        case .clearBassFiveBands:
            m.append(.equalizerAvailable(true))
            m.append(.equalizer(EqualizerParam(presetID: 0x00, steps: Array(repeating: 10, count: 6))))
            m.append(.equalizerPresets(inquiredType: 0, bands: 6, steps: 21,
                                       [0x00, 0x10, 0x11, 0x12, 0xA0].map { EqPreset(id: $0, name: "") }))
        case .tenBands:
            m.append(.equalizerAvailable(true))
            m.append(.equalizer(EqualizerParam(presetID: 0x00, steps: Array(repeating: 6, count: 10))))
            m.append(.equalizerPresets(inquiredType: 0, bands: 10, steps: 13,
                                       [0x00, 0x30, 0x31, 0x32, 0x33, 0xA0].map { EqPreset(id: $0, name: "") }))
        }
        if f.playback {
            m.append(.playback(PlaybackState(status: 0x01)))
            m.append(.volume(15))
        }
        for g in f.generalSettings {
            m.append(.generalSettingCapability(GeneralSettingCapability(inquiredType: g.inquiredType, subject: g.subject, summary: g.subject + "_SUMMARY")))
            m.append(.generalSetting(inquiredType: g.inquiredType, on: true))
        }
        if f.connectionPriority { m.append(.connectionPriority(ConnectionPriority(rawValue: 0))) }
        if f.dsee {
            m += [.dseeAvailable(true), .dsee(false), .dseeType(0x03)]
        }
        if f.autoPause { m.append(.autoPause(true)) }
        if f.speakToChat {
            m += [.speakToChat(false), .speakToChatConfig(SpeakToChatConfig(sensitivity: 0, modeOutTime: 1))]
        }
        return m
    }
}
