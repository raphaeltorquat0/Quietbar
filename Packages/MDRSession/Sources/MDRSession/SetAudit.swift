import MDRKit

/// Olha o tráfego, sem depender de quem pediu: é a medida independente de SET redundante (DECISIONS.md #137).
/// Redundante é o SET igual ao último estado que o fone informou, por GET ou NOTIFY.
public struct SetAudit: Sendable {
    public enum Finding: Sendable, Equatable {
        case sent(String), redundant(String), malformed
    }

    private var informed: [[UInt8]: [UInt8]] = [:]
    private var lastSent: [UInt8]?

    public init() {}

    public mutating func observe(_ direction: MDRSession.Direction, _ bytes: [UInt8]) -> Finding? {
        guard let frame = try? MDRFrame(decoding: bytes) else { return direction == .rx ? .malformed : nil }
        guard frame.type == .mdr || frame.type == .mdrNo2,
              let (verb, message) = MDRMessage.decode(frame.payload, table: frame.type == .mdr ? .t1 : .t2) else { return nil }
        let payload = message.command(.set).payload
        let key = [frame.type == .mdr ? 1 : 2] + payload.prefix(2)
        guard direction == .tx else {
            // O alerta é um pedido do fone, não estado: a resposta repete o código dele por definição.
            if case .alert = message { return nil }
            informed[key] = payload
            return nil
        }
        guard verb == .set else { return nil }
        // Sem ACK, a sessão repete o frame igual, com a mesma sequência. Isso não é outro SET.
        defer { lastSent = bytes }
        guard bytes != lastSent else { return nil }
        return informed[key] == payload ? .redundant("\(message)") : .sent("\(message)")
    }
}
