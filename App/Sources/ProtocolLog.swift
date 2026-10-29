import Foundation
import MDRKit
import MDRSession
import Observation

/// Log em memória dos frames MDR (últimos 2000), para a aba Desenvolvedor.
@MainActor @Observable final class ProtocolLog {
    static let shared = ProtocolLog()

    struct Entry: Identifiable {
        let id: Int
        let time: Date
        let outgoing: Bool
        let hex: String
        let decoded: String

        var line: String {
            "\(time.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))) \(outgoing ? ">>" : "<<") \(hex)  \(decoded)"
        }
    }

    private(set) var entries: [Entry] = []
    private var next = 0
    private let limit = 2000

    func add(_ dir: MDRSession.Direction, _ bytes: [UInt8]) {
        entries.append(Entry(id: next, time: Date(), outgoing: dir == .tx, hex: bytes.hex, decoded: MDRFrame.describe(bytes) ?? ""))
        next += 1
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    func clear() { entries.removeAll() }
}
