import Foundation

public enum MDRVerb: Sendable, Hashable {
    case get, ret, set, notify
}

/// Payload pronto para ir num frame: tabela + bytes (`cmd` + corpo).
public struct MDRCommand: Hashable, Sendable, CustomStringConvertible {
    public var table: MDRTable
    public var payload: [UInt8]

    public init(_ payload: [UInt8], table: MDRTable = .t1) {
        self.table = table
        self.payload = payload
    }

    public var description: String { "\(table) " + payload.hex }
}

// MARK: - Códigos de comando (docs/PROTOCOL.md §3.1)

enum Group: UInt8 {
    case common = 0x10, power = 0x20, eqebb = 0x50, ncasm = 0x60, alert = 0x90
    case play = 0xA0, generalSetting = 0xD0, audio = 0xE0, system = 0xF0
}

enum Aspect: UInt8 {
    case capability = 0x0, status = 0x2, param = 0x6, ext = 0xA

    init?(lowNibble n: UInt8) {
        switch n {
        case 0x0...0x1: self = .capability
        case 0x2...0x5: self = .status
        case 0x6...0x9: self = .param
        case 0xA...0xD: self = .ext
        default: return nil
        }
    }
}

func code(_ g: Group, _ a: Aspect, _ v: MDRVerb) -> UInt8 {
    let offset: UInt8 = switch v { case .get: 0; case .ret: 1; case .set: 2; case .notify: 3 }
    return g.rawValue | (a.rawValue + offset)
}

func verb(lowNibble n: UInt8, aspect: Aspect) -> MDRVerb? {
    switch n - aspect.rawValue {
    case 0: .get
    case 1: .ret
    case 2: aspect == .capability ? nil : .set
    case 3: aspect == .capability ? nil : .notify
    default: nil
    }
}

// MARK: - GETs

public extension MDRCommand {
    static let protocolInfo = MDRCommand([0x00, 0x00])
    static let capabilityInfo = MDRCommand([0x02, 0x00])
    static func deviceInfo(_ type: UInt8) -> MDRCommand { MDRCommand([0x04, type]) }
    static let modelName = deviceInfo(0x01)
    static let firmwareVersion = deviceInfo(0x02)
    static let seriesAndColor = deviceInfo(0x03)
    static func supportFunctions(_ table: MDRTable) -> MDRCommand { MDRCommand([0x06, 0x00], table: table) }

    internal static func get(_ g: Group, _ a: Aspect, _ body: UInt8...) -> MDRCommand { MDRCommand([code(g, a, .get)] + body) }

    static let codec = get(.common, .status, 0x02)
    static func battery(_ type: UInt8) -> MDRCommand { get(.power, .status, type) }
    static func autoPowerOff(_ type: UInt8) -> MDRCommand { get(.power, .param, type) }
    static func autoPowerOffOptions(_ type: UInt8) -> MDRCommand { get(.power, .capability, type) }
    static func noiseControl(_ type: UInt8) -> MDRCommand { get(.ncasm, .param, type) }
    static let ncAmbButton = get(.ncasm, .param, 0x30)
    static let equalizerAvailable = get(.eqebb, .status, 0x00)
    static let equalizer = get(.eqebb, .param, 0x00)
    /// Idioma `0x01` = inglês (o mesmo que [M] pede).
    static func equalizerPresets(_ type: UInt8) -> MDRCommand { get(.eqebb, .capability, type, 0x01) }
    static let dseeAvailable = get(.audio, .status, 0x01)
    static let dsee = get(.audio, .param, 0x01)
    static let dseeType = get(.audio, .capability, 0x01)
    static let connectionPriority = get(.audio, .param, 0x00)
    static let speakToChat = get(.system, .param, 0x0C)
    static let speakToChatConfig = get(.system, .ext, 0x0C)
    static let autoPause = get(.system, .param, 0x01)
    static func assignableButtons(_ type: UInt8) -> MDRCommand { get(.system, .param, type) }
    static func generalSettingCapability(_ type: UInt8) -> MDRCommand { get(.generalSetting, .capability, type, 0x01) }
    static func generalSetting(_ type: UInt8) -> MDRCommand { get(.generalSetting, .param, type) }
    static let volume = get(.play, .param, 0x20)
    static let playback = get(.play, .status, 0x01)
}

// MARK: - Mensagens de estado

/// Mensagem de estado da Tabela 1 (e a lista de funções da Tabela 2).
/// RET, NTFY e SET compartilham o layout; o verbo só muda o byte de comando.
public enum MDRMessage: Hashable, Sendable {
    case protocolInfo(version: UInt32, table1: Bool, table2: Bool)
    case capabilityInfo(counter: UInt8, uniqueID: String)
    case modelName(String)
    case firmwareVersion(String)
    case seriesAndColor(series: UInt8, color: UInt8)
    case supportFunctions([SupportFunction])
    case codec(AudioCodec)
    case battery(BatteryStatus)
    /// Earbuds: esquerdo/direito (inquired type `0x01`, ou `0x09` com threshold).
    case batteryLR(EarbudsBattery)
    /// Estojo de carga (`0x02`, ou `0x0A` com threshold).
    case batteryCase(BatteryStatus)
    case autoPowerOff(AutoPowerOff)
    case autoPowerOffOptions(wearingDetection: Bool, [UInt8])
    case powerOff
    case noiseControl(NoiseControl)
    case ncAmbButton(NcAmbButtonFunction)
    case equalizerAvailable(Bool)
    case equalizer(EqualizerParam)
    case equalizerPresets(inquiredType: UInt8, bands: UInt8, steps: UInt8, [EqPreset])
    case dseeAvailable(Bool)
    case dsee(Bool)
    case dseeType(UInt8)
    case connectionPriority(ConnectionPriority)
    case speakToChat(Bool)
    case speakToChatConfig(SpeakToChatConfig)
    case autoPause(Bool)
    case assignableButtons(inquiredType: UInt8, presets: [UInt8])
    case generalSettingCapability(GeneralSettingCapability)
    case generalSetting(inquiredType: UInt8, on: Bool)
    case volume(UInt8)
    case playback(PlaybackState)
    case playbackControl(PlaybackControl)
    case alertsEnabled(Bool)
    case alert(messageType: UInt8, action: UInt8)

    /// GET que relê o mesmo valor — usado para reconciliar depois de um SET.
    public var refresh: MDRCommand? {
        switch self {
        case .autoPowerOff(let a): .autoPowerOff(a.inquiredType)
        case .noiseControl(let n): .noiseControl(n.inquiredType)
        case .ncAmbButton: .ncAmbButton
        case .equalizer: .equalizer
        case .dsee: .dsee
        case .connectionPriority: .connectionPriority
        case .speakToChat: .speakToChat
        case .speakToChatConfig: .speakToChatConfig
        case .autoPause: .autoPause
        case .assignableButtons(let t, _): .assignableButtons(t)
        case .generalSetting(let t, _): .generalSetting(t)
        case .volume: .volume
        case .playbackControl: .playback
        default: nil
        }
    }

    // MARK: Encode

    public func command(_ verb: MDRVerb = .set) -> MDRCommand {
        let onOff: (Bool) -> UInt8 = { $0 ? 0x00 : 0x01 } // V2: ON/ENABLE = 0x00
        func p(_ g: Group, _ a: Aspect, _ body: [UInt8]) -> MDRCommand { MDRCommand([code(g, a, verb)] + body) }
        // CONNECT: RET = GET + 1.
        func c(_ get: UInt8, _ body: [UInt8]) -> MDRCommand { MDRCommand([verb == .get ? get : get + 1] + body) }

        switch self {
        case let .protocolInfo(v, t1, t2):
            return c(0x00, [0x00] + v.bigEndianBytes + [onOff(t1), onOff(t2)])
        case let .capabilityInfo(n, id): return c(0x02, [0x00, n] + id.prefixed)
        case .modelName(let s): return c(0x04, [0x01] + s.prefixed)
        case .firmwareVersion(let s): return c(0x04, [0x02] + s.prefixed)
        case let .seriesAndColor(s, col): return c(0x04, [0x03, s, col])
        case .supportFunctions(let fs): return c(0x06, [0x00, UInt8(fs.count)] + fs.flatMap { [$0.function, $0.priority] })
        case .codec(let k): return p(.common, .status, [0x02, k.rawValue])
        case .battery(let b):
            return b.withThreshold
                ? p(.power, .status, [0x08, b.level, b.chargingRaw, b.threshold ?? 0])
                : p(.power, .status, [0x00, b.level, b.chargingRaw])
        case .batteryLR(let b):
            let body = [b.left.level, b.left.chargingRaw, b.right.level, b.right.chargingRaw]
            return b.left.withThreshold
                ? p(.power, .status, [0x09] + body + [b.left.threshold ?? 0, b.right.threshold ?? 0])
                : p(.power, .status, [0x01] + body)
        case .batteryCase(let b):
            return b.withThreshold
                ? p(.power, .status, [0x0A, b.level, b.chargingRaw, b.threshold ?? 0])
                : p(.power, .status, [0x02, b.level, b.chargingRaw])
        case .autoPowerOff(let a): return p(.power, .param, [a.inquiredType, a.current, a.last])
        case let .autoPowerOffOptions(w, els): return p(.power, .capability, [w ? 0x05 : 0x04, UInt8(els.count)] + els)
        case .powerOff: return p(.power, .status, [0x03, 0x01])
        case .noiseControl(let n):
            let head: [UInt8] = [n.inquiredType, n.dragging ? 0x00 : 0x01, n.enabled ? 0x01 : 0x00]
            let tail: [UInt8] = [n.focusOnVoice ? 0x01 : 0x00, n.ambientLevel]
            return n.inquiredType == 0x22
                ? p(.ncasm, .param, head + tail)
                : p(.ncasm, .param, head + [n.ambientMode ? 0x01 : 0x00] + tail + n.extra)
        case .ncAmbButton(let f): return p(.ncasm, .param, [0x30, f.rawValue])
        case .equalizerAvailable(let on): return p(.eqebb, .status, [0x00, onOff(on)])
        case .equalizer(let e): return p(.eqebb, .param, [0x00, e.presetID, UInt8(e.steps.count)] + e.steps)
        case let .equalizerPresets(t, bands, steps, presets):
            return p(.eqebb, .capability, [t, bands, steps, UInt8(presets.count)] + presets.flatMap { [$0.id] + $0.name.prefixed })
        case .dseeAvailable(let on): return p(.audio, .status, [0x01, onOff(on)])
        case .dsee(let on): return p(.audio, .param, [0x01, on ? 0x01 : 0x00])
        case .dseeType(let t): return p(.audio, .capability, [0x01, t])
        case .connectionPriority(let m): return p(.audio, .param, [0x00, m.rawValue])
        case .speakToChat(let on): return p(.system, .param, [0x0C, onOff(on), onOff(false)])
        case .speakToChatConfig(let c): return p(.system, .ext, [0x0C, c.sensitivity, c.modeOutTime])
        case .autoPause(let on): return p(.system, .param, [0x01, onOff(on)])
        case let .assignableButtons(t, presets): return p(.system, .param, [t, UInt8(presets.count)] + presets)
        case .generalSettingCapability(let g):
            return p(.generalSetting, .capability, [g.inquiredType, g.settingType, g.stringFormat] + g.subject.prefixed + g.summary.prefixed)
        case let .generalSetting(t, on): return p(.generalSetting, .param, [t, 0x00, onOff(on)])
        case .volume(let v): return p(.play, .param, [0x20, v])
        case .playback(let s): return p(.play, .status, [0x01, onOff(s.enabled), s.status, s.inCall ? 0x01 : 0x00])
        case .playbackControl(let ctl): return p(.play, .status, [0x01, onOff(true), ctl.rawValue])
        case .alertsEnabled(let on): return p(.alert, .status, [0x00, onOff(on)])
        case let .alert(m, a): return p(.alert, .param, [0x00, m, a])
        }
    }

    // MARK: Decode

    /// Decodifica qualquer payload de estado. `nil` = desconhecido ou malformado (o chamador loga).
    public static func decode(_ payload: [UInt8], table: MDRTable = .t1) -> (MDRVerb, MDRMessage)? {
        var r = ByteReader(payload)
        guard let cmd = r.u8() else { return nil }
        if table == .t2 {
            guard cmd == 0x07, r.u8() == 0x00, let fs = r.supportFunctions() else { return nil }
            return (.ret, .supportFunctions(fs))
        }
        if cmd < 0x10 { return decodeConnect(cmd, &r).map { (.ret, $0) } }

        let isOn: (UInt8) -> Bool = { $0 == 0x00 }
        guard let g = Group(rawValue: cmd & 0xF0), let a = Aspect(lowNibble: cmd & 0x0F),
              let v = verb(lowNibble: cmd & 0x0F, aspect: a), v != .get,
              let type = r.u8() else { return nil }

        let m: MDRMessage? = switch (g, a, type) {
        case (.common, .status, 0x02): r.u8().map { .codec(AudioCodec(rawValue: $0)) }
        case (.power, .status, 0x00):
            r.u8s(2).map { .battery(BatteryStatus(level: $0[0], chargingRaw: $0[1])) }
        case (.power, .status, 0x08):
            r.u8s(3).map { .battery(BatteryStatus(level: $0[0], chargingRaw: $0[1], threshold: $0[2])) }
        case (.power, .status, 0x01):
            r.u8s(4).map { .batteryLR(EarbudsBattery(left: BatteryStatus(level: $0[0], chargingRaw: $0[1]),
                                                     right: BatteryStatus(level: $0[2], chargingRaw: $0[3]))) }
        case (.power, .status, 0x09):
            r.u8s(6).map { .batteryLR(EarbudsBattery(left: BatteryStatus(level: $0[0], chargingRaw: $0[1], threshold: $0[4]),
                                                     right: BatteryStatus(level: $0[2], chargingRaw: $0[3], threshold: $0[5]))) }
        case (.power, .status, 0x02):
            r.u8s(2).map { .batteryCase(BatteryStatus(level: $0[0], chargingRaw: $0[1])) }
        case (.power, .status, 0x0A):
            r.u8s(3).map { .batteryCase(BatteryStatus(level: $0[0], chargingRaw: $0[1], threshold: $0[2])) }
        case (.power, .status, 0x03): r.u8() == 0x01 ? .powerOff : nil
        case (.power, .param, 0x04), (.power, .param, 0x05):
            r.u8s(2).map { .autoPowerOff(AutoPowerOff(wearingDetection: type == 0x05, current: $0[0], last: $0[1])) }
        case (.power, .capability, 0x04), (.power, .capability, 0x05):
            r.list().map { .autoPowerOffOptions(wearingDetection: type == 0x05, $0) }
        case (.ncasm, .param, 0x15), (.ncasm, .param, 0x17), (.ncasm, .param, 0x19):
            r.u8s(5).map {
                .noiseControl(NoiseControl(inquiredType: type, dragging: $0[0] == 0x00, enabled: $0[1] == 0x01,
                                           ambientMode: $0[2] == 0x01, focusOnVoice: $0[3] == 0x01,
                                           ambientLevel: $0[4], extra: r.rest()))
            }
        case (.ncasm, .param, 0x22):
            r.u8s(4).map {
                .noiseControl(NoiseControl(inquiredType: type, dragging: $0[0] == 0x00, enabled: $0[1] == 0x01,
                                           ambientMode: true, focusOnVoice: $0[2] == 0x01, ambientLevel: $0[3]))
            }
        case (.ncasm, .param, 0x30): r.u8().map { .ncAmbButton(NcAmbButtonFunction(rawValue: $0)) }
        case (.eqebb, .status, 0x00): r.u8().map { .equalizerAvailable(isOn($0)) }
        case (.eqebb, .param, 0x00):
            r.u8().flatMap { id in r.list().map { .equalizer(EqualizerParam(presetID: id, steps: $0)) } }
        case (.eqebb, .capability, 0x00), (.eqebb, .capability, 0x02), (.eqebb, .capability, 0x03), (.eqebb, .capability, 0x04):
            r.eqPresets().map { .equalizerPresets(inquiredType: type, bands: $0.0, steps: $0.1, $0.2) }
        case (.audio, .status, 0x01): r.u8().map { .dseeAvailable(isOn($0)) }
        case (.audio, .param, 0x01): r.u8().map { .dsee($0 == 0x01) }
        case (.audio, .capability, 0x01): r.u8().map { .dseeType($0) }
        case (.audio, .param, 0x00): r.u8().map { .connectionPriority(ConnectionPriority(rawValue: $0)) }
        case (.system, .param, 0x0C): r.u8().map { .speakToChat(isOn($0)) }
        case (.system, .ext, 0x0C):
            r.u8s(2).map { .speakToChatConfig(SpeakToChatConfig(sensitivity: $0[0], modeOutTime: $0[1])) }
        case (.system, .param, 0x01): r.u8().map { .autoPause(isOn($0)) }
        case (.system, .param, 0x03), (.system, .param, 0x0E):
            r.list().map { .assignableButtons(inquiredType: type, presets: $0) }
        case (.generalSetting, .capability, 0xD1...0xD4):
            r.u8s(2).flatMap { h in
                r.str().flatMap { subject in
                    r.str().map {
                        .generalSettingCapability(GeneralSettingCapability(
                            inquiredType: type, settingType: h[0], stringFormat: h[1], subject: subject, summary: $0))
                    }
                }
            }
        case (.generalSetting, .param, 0xD1...0xD4): r.u8s(2).map { .generalSetting(inquiredType: type, on: isOn($0[1])) }
        case (.play, .param, 0x20): r.u8().map { .volume($0) }
        case (.play, .status, 0x01):
            if v == .set {
                r.u8s(2).map { .playbackControl(PlaybackControl(rawValue: $0[1])) }
            } else {
                r.u8s(3).map { .playback(PlaybackState(status: $0[1], enabled: isOn($0[0]), inCall: $0[2] == 0x01)) }
            }
        case (.alert, .status, 0x00): r.u8().map { .alertsEnabled(isOn($0)) }
        case (.alert, .param, 0x00): r.u8s(2).map { .alert(messageType: $0[0], action: $0[1]) }
        default: nil
        }
        return m.map { (v, $0) }
    }

    private static func decodeConnect(_ cmd: UInt8, _ r: inout ByteReader) -> MDRMessage? {
        switch cmd {
        case 0x01:
            guard r.u8() == 0x00, let b = r.u8s(6) else { return nil }
            let version = b[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return .protocolInfo(version: version, table1: b[4] == 0x00, table2: b[5] == 0x00)
        case 0x03:
            guard r.u8() == 0x00, let n = r.u8(), let id = r.str() else { return nil }
            return .capabilityInfo(counter: n, uniqueID: id)
        case 0x05:
            switch r.u8() {
            case 0x01: return r.str().map { .modelName($0) }
            case 0x02: return r.str().map { .firmwareVersion($0) }
            case 0x03: return r.u8s(2).map { .seriesAndColor(series: $0[0], color: $0[1]) }
            default: return nil
            }
        case 0x07:
            guard r.u8() == 0x00 else { return nil }
            return r.supportFunctions().map { .supportFunctions($0) }
        default:
            return nil
        }
    }
}

// MARK: - Helpers

struct ByteReader {
    private var bytes: ArraySlice<UInt8>
    init(_ b: [UInt8]) { bytes = b[...] }

    mutating func u8() -> UInt8? { bytes.popFirst() }

    mutating func u8s(_ n: Int) -> [UInt8]? {
        guard bytes.count >= n else { return nil }
        defer { bytes.removeFirst(n) }
        return Array(bytes.prefix(n))
    }

    mutating func list() -> [UInt8]? { u8().flatMap { u8s(Int($0)) } }
    mutating func str() -> String? { list().map { String(decoding: $0, as: UTF8.self) } }
    mutating func rest() -> [UInt8] { defer { bytes.removeAll() }; return Array(bytes) }

    mutating func supportFunctions() -> [SupportFunction]? {
        guard let n = u8(), let raw = u8s(Int(n) * 2) else { return nil }
        return stride(from: 0, to: raw.count, by: 2).map { SupportFunction(raw[$0], priority: raw[$0 + 1]) }
    }

    mutating func eqPresets() -> (UInt8, UInt8, [EqPreset])? {
        guard let h = u8s(3) else { return nil }
        var presets: [EqPreset] = []
        for _ in 0..<h[2] {
            guard let id = u8(), let name = str() else { return nil }
            presets.append(EqPreset(id: id, name: name))
        }
        return (h[0], h[1], presets)
    }
}

extension String {
    /// String com prefixo de tamanho de 1 byte (limite do protocolo: 255 bytes).
    var prefixed: [UInt8] {
        let b = Array(utf8.prefix(255))
        return [UInt8(b.count)] + b
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 24), UInt8(truncatingIfNeeded: self >> 16), UInt8(truncatingIfNeeded: self >> 8), UInt8(truncatingIfNeeded: self)] }
}

public extension Sequence<UInt8> {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
