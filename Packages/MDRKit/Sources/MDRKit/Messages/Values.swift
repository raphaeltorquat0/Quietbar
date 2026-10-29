import Foundation

// Valores de campo do MDR v2 Tabela 1. Códigos e fontes em docs/PROTOCOL.md §3.4.
// Structs RawRepresentable (e não enums) para que um código desconhecido do firmware não quebre o parse.

public struct AudioCodec: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let unsettled = AudioCodec(rawValue: 0x00)
    public static let sbc = AudioCodec(rawValue: 0x01)
    public static let aac = AudioCodec(rawValue: 0x02)
    public static let ldac = AudioCodec(rawValue: 0x10)
    public static let aptX = AudioCodec(rawValue: 0x20)
    public static let aptXHD = AudioCodec(rawValue: 0x21)
    public static let lc3 = AudioCodec(rawValue: 0x30)

    public var description: String {
        switch self {
        case .unsettled: "—"
        case .sbc: "SBC"
        case .aac: "AAC"
        case .ldac: "LDAC"
        case .aptX: "aptX"
        case .aptXHD: "aptX HD"
        case .lc3: "LC3"
        default: String(format: "0x%02X", rawValue)
        }
    }
}

public struct BatteryStatus: Hashable, Sendable {
    public enum Charging: UInt8, Sendable { case notCharging = 0, charging = 1, unknown = 2, charged = 3 }

    /// `true` quando veio do inquired type `0x08` (BATTERY_WITH_THRESHOLD).
    public var withThreshold: Bool
    public var level: UInt8
    public var chargingRaw: UInt8
    public var threshold: UInt8?

    public init(level: UInt8, chargingRaw: UInt8 = 0, threshold: UInt8? = nil) {
        self.withThreshold = threshold != nil
        self.level = level
        self.chargingRaw = chargingRaw
        self.threshold = threshold
    }

    public var charging: Charging { Charging(rawValue: chargingRaw) ?? .unknown }
    public var isCharging: Bool { charging == .charging }
}

public enum SoundMode: String, CaseIterable, Sendable, Codable {
    case noiseCanceling, ambient, off
}

/// NC/ASM (NCASM param). Os tipos `0x15` e `0x17` têm o mesmo layout; `0x19` traz 2 bytes a mais
/// (guardados em `extra`); `0x22` não tem byte de modo (só ambiente).
public struct NoiseControl: Hashable, Sendable {
    public var inquiredType: UInt8
    public var dragging: Bool
    public var enabled: Bool
    public var ambientMode: Bool
    public var focusOnVoice: Bool
    public var ambientLevel: UInt8
    public var extra: [UInt8]

    public init(inquiredType: UInt8 = 0x17, dragging: Bool = false, enabled: Bool, ambientMode: Bool,
                focusOnVoice: Bool = false, ambientLevel: UInt8, extra: [UInt8] = []) {
        self.inquiredType = inquiredType
        self.dragging = dragging
        self.enabled = enabled
        self.ambientMode = ambientMode
        self.focusOnVoice = focusOnVoice
        self.ambientLevel = ambientLevel
        self.extra = extra
    }

    public var soundMode: SoundMode {
        get { !enabled ? .off : ambientMode ? .ambient : .noiseCanceling }
        set {
            enabled = newValue != .off
            if newValue != .off { ambientMode = newValue == .ambient }
        }
    }
}

/// Função do botão NC/AMB (NCASM inquired type `0x30`): quais modos ele percorre.
public struct NcAmbButtonFunction: RawRepresentable, Hashable, Sendable, CaseIterable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let ncAmbientOff = NcAmbButtonFunction(rawValue: 0x01)
    public static let ncAmbient = NcAmbButtonFunction(rawValue: 0x02)
    public static let ncOff = NcAmbButtonFunction(rawValue: 0x03)
    public static let ambientOff = NcAmbButtonFunction(rawValue: 0x04)
    public static let allCases: [NcAmbButtonFunction] = [.ncAmbientOff, .ncAmbient, .ncOff, .ambientOff]
}

public struct EqualizerParam: Hashable, Sendable {
    public var presetID: UInt8
    /// Passos crus do fone. Com 6 bandas: `[Clear Bass, 400, 1k, 2.5k, 6.3k, 16k]`, valor = dB + 10.
    public var steps: [UInt8]

    public init(presetID: UInt8, steps: [UInt8] = []) {
        self.presetID = presetID
        self.steps = steps
    }

    public static let customPresetID: UInt8 = 0xA0
    public static let fiveBandLabels = ["400", "1k", "2.5k", "6.3k", "16k"]

    /// Constrói o EQ de 5 bandas + Clear Bass a partir de valores em dB (−10…+10).
    public init(presetID: UInt8 = customPresetID, clearBass: Int, bands: [Int]) {
        precondition(bands.count == 5, "o XM5 tem 5 bandas")
        self.presetID = presetID
        self.steps = ([clearBass] + bands).map { UInt8(clamping: min(10, max(-10, $0)) + 10) }
    }

    public var isFiveBand: Bool { steps.count == 6 }
    public var clearBass: Int? { isFiveBand ? Int(steps[0]) - 10 : nil }
    public var bands: [Int] {
        switch steps.count {
        case 6: steps.dropFirst().map { Int($0) - 10 }
        case 10: steps.map { Int($0) - 6 }
        default: []
        }
    }
}

public struct EqPreset: Hashable, Sendable, Identifiable {
    public var id: UInt8
    public var name: String
    public init(id: UInt8, name: String) { self.id = id; self.name = name }

    /// O XM5 manda a lista só com IDs (nomes vazios); aí vale o nome conhecido.
    public var displayName: String { name.isEmpty ? Self.knownNames[id] ?? String(format: "Preset 0x%02X", id) : name }

    /// Nomes de fallback quando o fone não manda a lista (IDs de `EqPresetId` em [M]).
    public static let knownNames: [UInt8: String] = [
        0x00: "Off", 0x10: "Bright", 0x11: "Excited", 0x12: "Mellow", 0x13: "Relaxed", 0x14: "Vocal",
        0x15: "Treble Boost", 0x16: "Bass Boost", 0x17: "Speech", 0xA0: "Custom",
        0xA1: "User Setting 1", 0xA2: "User Setting 2", 0xA3: "User Setting 3",
        0xA4: "User Setting 4", 0xA5: "User Setting 5",
    ]
}

public struct AutoPowerOff: Hashable, Sendable {
    public var wearingDetection: Bool
    public var current: UInt8
    public var last: UInt8

    public init(wearingDetection: Bool, current: UInt8, last: UInt8 = 0x00) {
        self.wearingDetection = wearingDetection
        self.current = current
        self.last = last
    }

    public var inquiredType: UInt8 { wearingDetection ? 0x05 : 0x04 }

    public static func label(_ element: UInt8) -> String {
        switch element {
        case 0x00: "5 min"
        case 0x04: "15 min"
        case 0x01: "30 min"
        case 0x02: "1 h"
        case 0x03: "3 h"
        case 0x10: "Ao tirar o fone"
        case 0x11: "Nunca"
        default: String(format: "0x%02X", element)
        }
    }
}

/// Prioridade de conexão (AUDIO param `0x00`).
public struct ConnectionPriority: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let soundQuality = ConnectionPriority(rawValue: 0x00)
    public static let stability = ConnectionPriority(rawValue: 0x01)
}

public struct SpeakToChatConfig: Hashable, Sendable {
    /// `00` auto, `01` alta, `02` baixa.
    public var sensitivity: UInt8
    /// `00` curto, `01` médio, `02` longo, `03` não voltar sozinho.
    public var modeOutTime: UInt8
    public init(sensitivity: UInt8, modeOutTime: UInt8) {
        self.sensitivity = sensitivity
        self.modeOutTime = modeOutTime
    }
}

public struct GeneralSettingCapability: Hashable, Sendable {
    /// `0xD1`…`0xD4`.
    public var inquiredType: UInt8
    public var settingType: UInt8
    public var stringFormat: UInt8
    public var subject: String
    public var summary: String

    public init(inquiredType: UInt8, settingType: UInt8 = 0, stringFormat: UInt8 = 1, subject: String, summary: String) {
        self.inquiredType = inquiredType
        self.settingType = settingType
        self.stringFormat = stringFormat
        self.subject = subject
        self.summary = summary
    }

    public var isBoolean: Bool { settingType == 0x00 }
}

public struct PlaybackState: Hashable, Sendable {
    /// `01` play, `02` pause, `03` stop.
    public var status: UInt8
    public var enabled: Bool
    public var inCall: Bool
    public init(status: UInt8, enabled: Bool = true, inCall: Bool = false) {
        self.status = status
        self.enabled = enabled
        self.inCall = inCall
    }
    public var isPlaying: Bool { status == 0x01 }
}

public struct PlaybackControl: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let pause = PlaybackControl(rawValue: 0x01)
    public static let next = PlaybackControl(rawValue: 0x02)
    public static let previous = PlaybackControl(rawValue: 0x03)
    public static let play = PlaybackControl(rawValue: 0x07)
}

/// Presets do botão personalizável (SYSTEM param `0x03`).
public enum AssignablePreset {
    public static func label(_ raw: UInt8) -> String {
        switch raw {
        case 0x00: "Controle de som ambiente"
        case 0x10: "Volume"
        case 0x20: "Reprodução"
        case 0x21: "Faixas"
        case 0x30: "Assistente de voz"
        case 0x31: "Google Assistant"
        case 0x32: "Amazon Alexa"
        case 0x35: "Som ambiente + Quick Access"
        case 0x36: "Quick Access"
        case 0xFF: "Sem função"
        default: String(format: "Preset 0x%02X", raw)
        }
    }
}

public struct SupportFunction: Hashable, Sendable {
    public var function: UInt8
    public var priority: UInt8
    public init(_ function: UInt8, priority: UInt8 = 0xFF) {
        self.function = function
        self.priority = priority
    }
}
