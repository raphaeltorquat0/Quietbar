import MDRKit

/// Protocolo BLE dos JBL recentes ("Protocol4"). Fontes, só como fato (`docs/JBL.md`): NeoHBz/JBLProtocol4,
/// `notes/protocol.md` (MIT), medido num Tune 780NC; e o app JBL Headphones 5.38.2 para Android, lido estaticamente.
///
/// Frame little-endian: `00 dd | cmd u16 | count u8 | index u8 | len u16 | payload`.
/// Payload de SET e de resposta: TLV `tag u16 | len u16 | valor`. Resposta e NOTIFY começam com status `u16`.
public enum JBL {
    public static let service = "65786365-6C70-6F69-6E74-2E636F6D0000"
    public static let notify = "65786365-6C70-6F69-6E74-2E636F6D0001"
    public static let write = "65786365-6C70-6F69-6E74-2E636F6D0002"
    /// Canal "raw": só nos modelos com `bleSecurityMode` 3, onde passa o HostNameCRC antes de tudo.
    public static let raw = "65786365-6C70-6F69-6E74-2E636F6D0003"

    public enum Command: UInt16, Sendable {
        case get = 0x0001, set = 0x0002, notification = 0x0003
    }

    public enum Tag {
        public static let productID: UInt16 = 0x0004
        public static let hostNameCRC: UInt16 = 0x0007
        public static let leftBattery: UInt16 = 0x000D
        public static let rightBattery: UInt16 = 0x000E
        public static let anc: UInt16 = 0x0018
        public static let ambientAware: UInt16 = 0x0019
        public static let talkThru: UInt16 = 0x001A
        public static let hostType: UInt16 = 0x002F
        /// Liga/desliga o grupo inteiro nos `LiveTws4`. Desligado, o fone mantém o tag do último modo ligado e só
        /// este vai a `7f` (medido no Live Beam 4): sem ele na leitura, desligado parece ligado.
        public static let ambientSoundControl: UInt16 = 0x0049
        public static let caseBattery: UInt16 = 0x1F03
    }

    /// Só estes tags podem ir num SET. Reset (`0x00FF`), OTA, power-off e autenticação nunca saem daqui.
    static let writableTags: Set<UInt16> = [Tag.hostNameCRC, Tag.hostType, Tag.anc, Tag.ambientAware, Tag.talkThru,
                                            Tag.ambientSoundControl]

    /// PIDs que usam `LiveTws4Control` no app: Live Beam 4 (`2179`) e Live Buds 4 (`217b`).
    /// O modo vai com `AmbientSoundControl`, e a bateria vem por fone e do estojo.
    public static let liveTws4: Set<UInt16> = [0x2179, 0x217B]

    public struct Frame: Equatable, Sendable {
        public var command: UInt16
        public var count: UInt8 = 1
        public var index: UInt8 = 0
        public var payload: [UInt8]

        public var encoded: [UInt8] {
            [0x00, 0xDD] + command.le + [count, index] + UInt16(payload.count).le + payload
        }

        public init(command: UInt16, count: UInt8 = 1, index: UInt8 = 0, payload: [UInt8]) {
            self.command = command
            self.count = count
            self.index = index
            self.payload = payload
        }

        public init?(decoding b: [UInt8]) {
            guard b.count >= 8, b[1] == 0xDD else { return nil }
            let size = Int(UInt16(b[6]) | UInt16(b[7]) << 8)
            guard b.count >= 8 + size else { return nil }
            self.init(command: UInt16(b[2]) | UInt16(b[3]) << 8, count: b[4], index: b[5], payload: Array(b[8..<8 + size]))
        }
    }

    public static func get(_ tags: [UInt16]) -> Frame {
        Frame(command: Command.get.rawValue, payload: tags.flatMap(\.le))
    }

    /// `nil` se algum tag estiver fora de `writableTags`.
    public static func set(_ values: [(tag: UInt16, value: [UInt8])]) -> Frame? {
        guard values.allSatisfy({ writableTags.contains($0.tag) }) else { return nil }
        return Frame(command: Command.set.rawValue, payload: values.flatMap { $0.tag.le + UInt16($0.value.count).le + $0.value })
    }

    public static func set(_ tag: UInt16, _ value: [UInt8]) -> Frame? { set([(tag, value)]) }

    /// TLVs de uma resposta ou NOTIFY, sem o status. `nil` se o status não for `0000` ou o TLV vier truncado.
    public static func values(_ payload: [UInt8]) -> [UInt16: [UInt8]]? {
        guard payload.count >= 2, payload[0] == 0, payload[1] == 0 else { return nil }
        var out: [UInt16: [UInt8]] = [:]
        var i = 2
        while i + 4 <= payload.count {
            let tag = UInt16(payload[i]) | UInt16(payload[i + 1]) << 8
            let len = Int(UInt16(payload[i + 2]) | UInt16(payload[i + 3]) << 8)
            guard i + 4 + len <= payload.count else { return nil }
            out[tag] = Array(payload[i + 4..<i + 4 + len])
            i += 4 + len
        }
        return out
    }

    /// Junta os pacotes de uma mensagem longa (count > 1). Cada pacote tem o próprio cabeçalho.
    public struct Reassembler: Sendable {
        private var pending: Frame?

        public init() {}

        public mutating func push(_ bytes: [UInt8]) -> Frame? {
            guard let f = Frame(decoding: bytes) else { return nil }
            if f.count <= 1 { pending = nil; return f }
            if f.index == 0 { pending = f } else if pending?.command == f.command { pending?.payload += f.payload } else { return nil }
            guard f.index == f.count - 1, var whole = pending else { return nil }
            pending = nil
            whole.count = 1
            whole.index = 0
            return whole
        }
    }

    // MARK: Identidade do host

    /// CRC-16/ARC do nome Bluetooth do host, nos primeiros 50 bytes em UTF-8. O fone anuncia o CRC dos hosts
    /// pareados e, no modo de segurança 3, espera o mesmo valor no tag `0x0007` antes de responder.
    public static func hostNameCRC(_ name: String) -> UInt16 {
        var crc: UInt16 = 0
        for b in name.utf8.prefix(50) {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc
    }

    public static func setHostNameCRC(_ name: String) -> Frame { set(Tag.hostNameCRC, hostNameCRC(name).le)! }

    // MARK: Modo de som

    /// Byte de estado: bit 7 = ligado, bits 0-6 = nível.
    static func status(_ on: Bool, level: UInt8 = 0x7F) -> UInt8 { (on ? 0x80 : 0) | (level & 0x7F) }

    /// ANC ↔ cancelamento; Ambient Aware ↔ ambiente; TalkThru ↔ ambiente com foco na voz.
    public static func modeTag(for n: NoiseControl) -> UInt16 {
        !n.ambientMode ? Tag.anc : n.focusOnVoice ? Tag.talkThru : Tag.ambientAware
    }

    /// SET do modo. Genérico (spec): um tag do grupo, com `7f` desligando os três.
    /// `LiveTws4`: `AmbientSoundControl` liga ou desliga, mais o tag do modo ligado (`LiveTws4Control.setAncSetting`).
    public static func setMode(_ n: NoiseControl, liveTws4: Bool = false, aaLevel: UInt8 = 0x7F) -> Frame? {
        let tag = modeTag(for: n)
        let level = tag == Tag.ambientAware ? aaLevel : 0x7F
        guard liveTws4 else { return set(n.enabled ? tag : Tag.anc, [status(n.enabled, level: level)]) }
        return set([(Tag.ambientSoundControl, [status(n.enabled)]), (tag, [status(true, level: level)])])
    }

    /// Estado do grupo. O modo é o tag com o bit 7 ligado, e `AmbientSoundControl`, se vier, manda no liga/desliga.
    public static func noiseControl(_ v: [UInt16: [UInt8]], base: NoiseControl) -> NoiseControl? {
        func isOn(_ t: UInt16) -> Bool? { v[t]?.first.map { $0 & 0x80 != 0 } }
        guard let anc = isOn(Tag.anc), let amb = isOn(Tag.ambientAware), let talk = isOn(Tag.talkThru) else { return nil }
        var n = base
        n.enabled = (anc || amb || talk) && isOn(Tag.ambientSoundControl) != false
        if anc || amb || talk {
            n.ambientMode = !anc
            n.focusOnVoice = talk
        }
        return n
    }

    static func battery(_ v: [UInt16: [UInt8]], _ tag: UInt16) -> BatteryStatus? {
        v[tag]?.first.map { BatteryStatus(level: $0 & 0x7F, chargingRaw: $0 & 0x80 != 0 ? 1 : 0) }
    }
}

/// Um JBL vestido de fone MDR: responde à `MDRSession` com uma tabela de RETs e traduz SET de modo
/// para o protocolo JBL. Assim o painel, a automação e os Atalhos não precisam saber que é outra marca.
/// Puro: entra um frame, saem frames. A E/S fica no `JBLChannel`.
public struct JBLBridge: Sendable {
    public struct Output: Equatable, Sendable {
        public var mdr: [MDRFrame] = []
        public var jbl: [JBL.Frame] = []
    }

    /// GET (2 primeiros bytes) → payload do RET.
    private var answers: [[UInt8]: [UInt8]] = [:]
    private var seq: UInt8 = 0
    public private(set) var noise = NoiseControl(enabled: false, ambientMode: false, ambientLevel: 0)
    /// `nil` até o fone responder o GET de `ProductID`.
    public private(set) var productID: UInt16?
    private var aaLevel: UInt8 = 0x7F

    public var isLiveTws4: Bool { productID.map(JBL.liveTws4.contains) ?? false }

    public init(modelName: String) {
        for m: MDRMessage in [
            .protocolInfo(version: 0x0300_0000, table1: true, table2: false),
            .capabilityInfo(counter: 1, uniqueID: modelName),
            .firmwareVersion("—"),
            .modelName(modelName),
            .seriesAndColor(series: 0, color: 0),
            .noiseControl(noise),
        ] { store(m) }
        storeFunctions()
    }

    /// Ao abrir: HostType e a leitura inicial (spec: notify → HostType → GETs). O `JBLChannel` espera a
    /// resposta com o `ProductID` antes de entregar o canal, porque as funções anunciadas dependem dele.
    public static let handshake: [JBL.Frame] = [
        JBL.set(JBL.Tag.hostType, [0x01])!,
        JBL.get([JBL.Tag.productID, JBL.Tag.leftBattery, JBL.Tag.rightBattery, JBL.Tag.caseBattery,
                 JBL.Tag.anc, JBL.Tag.ambientAware, JBL.Tag.talkThru, JBL.Tag.ambientSoundControl]),
    ]

    /// Frame MDR vindo da sessão.
    public mutating func receive(_ frame: MDRFrame) -> Output {
        guard frame.type == .mdr, !frame.payload.isEmpty else { return Output() }
        var out = Output(mdr: [.ack(for: frame.seq)])
        let command = MDRCommand(frame.payload)
        if command.isRead {
            if frame.payload.count >= 2, let ret = answers[Array(frame.payload.prefix(2))] { out.mdr.append(data(ret)) }
        } else if case (.set, .noiseControl(var n))? = MDRMessage.decode(frame.payload) {
            // A UI espera a releitura, então o valor pedido vale até o NOTIFY do fone confirmar ou corrigir.
            // O nível de ambiente não tem par no JBL: o Live Beam 4 guarda `0x19` de 0 a 0x20, mas o som não muda
            // (conferido de ouvido, docs/JBL.md §5). Mudar só o nível não sai para o fone.
            n.inquiredType = noise.inquiredType
            let changed = n.enabled != noise.enabled || (n.enabled && JBL.modeTag(for: n) != JBL.modeTag(for: noise))
            if changed, let set = JBL.setMode(n, liveTws4: isLiveTws4, aaLevel: aaLevel) { out.jbl.append(set) }
            noise = n
            store(.noiseControl(n))
        }
        return out
    }

    /// Resposta ou NOTIFY do JBL → NOTIFY MDR do que mudou.
    public mutating func receive(_ frame: JBL.Frame) -> [MDRFrame] {
        guard let v = JBL.values(frame.payload) else { return [] }
        if let p = v[JBL.Tag.productID], p.count == 2 {
            productID = UInt16(p[0]) | UInt16(p[1]) << 8
            storeFunctions()
        }
        if let a = v[JBL.Tag.ambientAware]?.first { aaLevel = a & 0x7F }
        var out: [MDRFrame] = []
        if isLiveTws4 {
            if let l = JBL.battery(v, JBL.Tag.leftBattery), let r = JBL.battery(v, JBL.Tag.rightBattery) {
                out.append(event(.batteryLR(EarbudsBattery(left: l, right: r))))
            }
            if let c = JBL.battery(v, JBL.Tag.caseBattery) { out.append(event(.batteryCase(c))) }
        } else if let b = JBL.battery(v, JBL.Tag.leftBattery) {
            out.append(event(.battery(b)))
        }
        if let n = JBL.noiseControl(v, base: noise), n != noise {
            noise = n
            out.append(event(.noiseControl(n)))
        }
        return out
    }

    /// Funções anunciadas (`docs/PROTOCOL.md` §3.3): bateria e NC/ambiente. Earbuds: esquerdo/direito (`0x21`)
    /// e estojo (`0x22`), sem limiar. Nada de EQ, codec ou multiponto, que ainda não foram decodificados.
    private mutating func storeFunctions() {
        let functions: [UInt8] = isLiveTws4 ? [0x21, 0x22, 0x6B] : [0x20, 0x6B]
        store(.supportFunctions(functions.map { SupportFunction($0) }))
    }

    private mutating func event(_ m: MDRMessage) -> MDRFrame {
        store(m)
        return data(m.command(.notify).payload)
    }

    private mutating func store(_ m: MDRMessage) {
        answers[Array(m.command(.get).payload.prefix(2))] = m.command(.ret).payload
    }

    private mutating func data(_ payload: [UInt8]) -> MDRFrame {
        defer { seq = 1 &- seq }
        return MDRFrame(type: .mdr, seq: seq, payload: payload)
    }
}

extension UInt16 {
    var le: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8)] }
}
