import MDRKit

/// Fone virtual: responde GET e SET com frames MDR v2 válidos, guarda o estado e emite NOTIFY.
/// Não tem tempo nem E/S: entra um frame, saem os frames de resposta. Latência fica no `VirtualTransport`.
public struct VirtualDevice: Sendable {
    public let profile: DeviceProfile

    /// GET → payload do RET. A chave são os dois primeiros bytes do GET, os que identificam o valor
    /// (o resto é idioma ou filtro, como em `50 00 01`).
    private var answers: [Key: [UInt8]] = [:]
    private var seq: UInt8 = 0
    /// Alerta enviado ao host, à espera da resposta, com o valor que ele confirma.
    private var pendingAlert: (type: UInt8, on: Bool)?
    /// SETs que o MDRKit não decodifica: o fone confirma e não muda nada.
    public private(set) var unknownSets: [[UInt8]] = []

    private struct Key: Hashable {
        let table: MDRTable
        let cmd: UInt8
        let type: UInt8
    }

    public init(profile: DeviceProfile) {
        self.profile = profile
        for m in profile.derivedResponses { store(m) }
        store(table: .t1, .supportFunctions(profile.derivedFunctions.map { SupportFunction($0) }))
        if profile.hasTable2 { store(table: .t2, .supportFunctions([])) }
        // A captura vence o que foi derivado: nesses perfis, o que veio do fone é byte a byte.
        if case .capture(let fixtures, _) = profile.origin {
            for f in fixtures.flatMap({ CapturedFrames.frames($0) }) where f.direction == "rx" { record(f.frame) }
        }
    }

    /// Valor atual, decodificado, do mesmo jeito que o host leria.
    public func current(_ get: MDRCommand) -> MDRMessage? {
        answer(to: get).flatMap { MDRMessage.decode($0, table: get.table)?.1 }
    }

    /// Payload exato do RET para este GET.
    public func answer(to get: MDRCommand) -> [UInt8]? {
        guard get.payload.count >= 2 else { return nil }
        return answers[Key(table: get.table, cmd: get.payload[0], type: get.payload[1])]
    }

    // MARK: Protocolo

    /// Um frame do host. ACKs do host não pedem resposta.
    public mutating func receive(_ frame: MDRFrame) -> [MDRFrame] {
        guard frame.type == .mdr || frame.type == .mdrNo2, !frame.payload.isEmpty else { return [] }
        let table: MDRTable = frame.type == .mdr ? .t1 : .t2
        var out = [MDRFrame.ack(for: frame.seq)]
        let command = MDRCommand(frame.payload, table: table)
        if let ret = answer(to: command), Self.isGet(frame.payload[0]) {
            out.append(data(ret, table))
        } else if let (verb, message) = MDRMessage.decode(frame.payload, table: table), verb == .set {
            out += apply(message)
        } else if !Self.isGet(frame.payload[0]) {
            unknownSets.append(frame.payload)
        }
        return out
    }

    /// Mudança espontânea no fone (botão, bateria): atualiza o estado e devolve o NOTIFY.
    public mutating func event(_ message: MDRMessage) -> MDRFrame {
        store(message)
        return data(message.command(.notify).payload, .t1)
    }

    private mutating func apply(_ message: MDRMessage) -> [MDRFrame] {
        switch message {
        case .alertsEnabled:
            return []
        case let .alert(_, action):
            guard let p = pendingAlert else { return [] }
            pendingAlert = nil
            return action == 0x01 ? [event(.generalSetting(inquiredType: p.type, on: p.on))] : []
        case let .generalSetting(type, on) where isMultipoint(type):
            // O fone pede confirmação antes de alternar o multiponto (DECISIONS.md #7).
            pendingAlert = (type, on)
            return [data(MDRMessage.alert(messageType: 0x06, action: 0x01).command(.notify).payload, .t1)]
        case .equalizer(let eq) where eq.steps.isEmpty:
            guard case .equalizer(let old)? = current(.equalizer) else { return [event(message)] }
            return [event(.equalizer(EqualizerParam(presetID: eq.presetID, steps: old.steps)))]
        case .playbackControl(let control):
            let playing = control == .play
            return [event(.playback(PlaybackState(status: playing ? 0x01 : 0x02)))]
        default:
            return [event(message)]
        }
    }

    private func isMultipoint(_ type: UInt8) -> Bool {
        guard case .generalSettingCapability(let c)? = current(.generalSettingCapability(type)) else { return false }
        return c.subject.hasPrefix("MULTIPOINT")
    }

    private mutating func data(_ payload: [UInt8], _ table: MDRTable) -> MDRFrame {
        defer { seq = 1 &- seq }
        return MDRFrame(type: table.dataType, seq: seq, payload: payload)
    }

    // MARK: Estado

    private mutating func store(table: MDRTable = .t1, _ message: MDRMessage) {
        record(payload: message.command(.ret).payload, table: table)
    }

    private mutating func record(_ frame: MDRFrame) {
        guard frame.type == .mdr || frame.type == .mdrNo2 else { return }
        record(payload: frame.payload, table: frame.type == .mdr ? .t1 : .t2)
    }

    private mutating func record(payload: [UInt8], table: MDRTable) {
        guard payload.count >= 2, let get = Self.getCode(for: payload[0]) else { return }
        answers[Key(table: table, cmd: get, type: payload[1])] = payload
    }

    /// RET ou NOTIFY → byte do GET correspondente (`docs/PROTOCOL.md` §3.1 e §3.2).
    static func getCode(for cmd: UInt8) -> UInt8? {
        if cmd < 0x10 { return cmd & 1 == 1 ? cmd - 1 : nil }
        let n = cmd & 0x0F, base: UInt8
        switch n {
        case 0x0...0x1: base = 0x0
        case 0x2...0x5: base = 0x2
        case 0x6...0x9: base = 0x6
        case 0xA...0xD: base = 0xA
        default: return nil
        }
        return n - base == 1 || n - base == 3 ? (cmd & 0xF0) | base : nil
    }

    static func isGet(_ cmd: UInt8) -> Bool {
        if cmd < 0x10 { return cmd & 1 == 0 }
        let n = cmd & 0x0F
        return n == 0x0 || n == 0x2 || n == 0x6 || n == 0xA
    }
}
