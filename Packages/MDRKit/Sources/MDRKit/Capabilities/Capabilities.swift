/// Funções anunciadas pelo fone (`CONNECT_RET_SUPPORT_FUNCTION`) e o que elas habilitam.
/// O mapeamento função → inquired type segue `RequestInitV2` de [M] (docs/PROTOCOL.md §3.3).
public struct MDRCapabilities: Hashable, Sendable {
    public var table1: Set<UInt8>
    public var table2: Set<UInt8>
    /// `true` quando veio do perfil de fallback, não do fone.
    public var isFallback: Bool

    public init(table1: Set<UInt8> = [], table2: Set<UInt8> = [], isFallback: Bool = false) {
        self.table1 = table1
        self.table2 = table2
        self.isFallback = isFallback
    }

    /// Perfil do WH-1000XM5 para quando o fone não responder às funções suportadas:
    /// a lista exata que um WH-1000XM5 fw 2.5.1 anunciou ao `mdr-cli dump` (2026-10-29).
    public static let wh1000xm5 = MDRCapabilities(
        table1: [0x10, 0x12, 0x13, 0x14, 0x19, 0x20, 0x23, 0x25, 0x27, 0x32, 0x50, 0x69, 0x6B, 0x70, 0x90, 0x93,
                 0xA1, 0xB0, 0xB2, 0xB6, 0xB7, 0xB8, 0xC1, 0xC2, 0xD1, 0xD2, 0xE1, 0xE2, 0xF1, 0xF4, 0xF9, 0xFC, 0xFD],
        table2: [0x31, 0x32, 0x41, 0x50, 0xF2, 0xF8],
        isFallback: true
    )

    func has(_ f: UInt8) -> Bool { table1.contains(f) }

    public var codec: Bool { has(0x12) }
    public var powerOff: Bool { has(0x23) }
    public var alerts: Bool { has(0x90) }
    public var playback: Bool { (0xA1...0xA4).contains { has($0) } }
    public var dsee: Bool { has(0xE2) }
    public var connectionPriority: Bool { has(0xE1) }
    public var autoPause: Bool { has(0xF1) }
    public var speakToChat: Bool { has(0xFC) }
    public var ncAmbButton: Bool { has(0x69) }

    public var batteryType: UInt8? { has(0x20) ? 0x00 : has(0x28) ? 0x08 : nil }
    public var autoPowerOffType: UInt8? { has(0x25) ? 0x05 : has(0x24) ? 0x04 : nil }

    public var noiseControlType: UInt8? {
        if has(0x6B) { return 0x17 }
        if has(0x6D) { return 0x19 }
        if has(0x68) { return 0x15 }
        if has(0x67) { return 0x22 }
        return nil
    }

    /// Inquired type para a lista de presets (`EqPresetInquiredType` em [M]).
    public var equalizerType: UInt8? {
        if has(0x50) { return 0x00 }
        if has(0x52) { return 0x02 }
        if has(0x53) { return 0x03 }
        if has(0x57) { return 0x04 }
        return nil
    }

    public var assignableType: UInt8? { has(0xFE) ? 0x0E : has(0xF3) ? 0x03 : nil }

    /// `0xD1`…`0xD4` anunciados.
    public var generalSettings: [UInt8] { (0xD1...0xD4).filter { has($0) } }
}
