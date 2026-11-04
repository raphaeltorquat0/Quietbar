import Foundation
import MDRKit
import MDRSession
import Observation

/// Log em memória dos frames MDR (últimos 2000) e de avisos do app, para a aba Desenvolvedor.
@MainActor @Observable final class ProtocolLog {
    static let shared = ProtocolLog()

    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let outgoing: Bool
        let hex: String
        let decoded: String

        var line: String {
            let clock = time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
            return hex.isEmpty ? "\(clock) -- \(decoded)" : "\(clock) \(outgoing ? ">>" : "<<") \(hex)  \(decoded)"
        }
    }

    private(set) var entries: [Entry] = []
    private var next = 0
    private let limit = 2000

    func add(_ dir: MDRSession.Direction, _ bytes: [UInt8]) {
        append(outgoing: dir == .tx, hex: bytes.hex, decoded: MDRFrame.describe(bytes) ?? "")
    }

    /// Aviso do app, sem frame.
    func note(_ text: String) { append(outgoing: false, hex: "", decoded: text) }

    private func append(outgoing: Bool, hex: String, decoded: String) {
        entries.append(Entry(id: next, time: Date(), outgoing: outgoing, hex: hex, decoded: decoded))
        next += 1
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}
