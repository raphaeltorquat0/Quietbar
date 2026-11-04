import CryptoKit
import Foundation

/// Eventos do teste interno em JSONL, um arquivo por dia. Só grava em disco: não conhece rede nem o app.
/// Passando do limite, saem os dias mais antigos; se só sobrar hoje, o resto do dia se perde com um aviso.
public final class DogfoodLog: @unchecked Sendable {
    public static let defaultLimit = 50 * 1024 * 1024

    private let directory: URL
    private let limit: Int
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let queue = DispatchQueue(label: "quietbar.dogfood", qos: .utility)
    private var used: Int?
    private var full = false
    private var day = ""

    public init(directory: URL, limit: Int = DogfoodLog.defaultLimit, now: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.directory = directory
        self.limit = limit
        self.now = now
        self.timeZone = timeZone
    }

    /// Campos `nil` ficam de fora. A ordem das linhas é a das chamadas.
    public func append(_ event: String, _ fields: [String: Any?] = [:]) {
        let date = now()
        var object = fields.compactMapValues { $0 }
        object["ev"] = event
        object["t"] = stamp(date)
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        let line = json + Data("\n".utf8)
        queue.async { [self] in write(line, on: date) }
    }

    /// Espera o que está na fila: ao encerrar o app e nos testes.
    public func flush() { queue.sync {} }

    /// Nome de rede nunca vai em texto. O sal evita comparar com uma lista de nomes comuns.
    public func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data((queue.sync { salt() } + text).utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func salt() -> String {
        let url = directory.appending(path: "salt")
        if let saved = try? String(contentsOf: url, encoding: .utf8), !saved.isEmpty { return saved }
        let new = UUID().uuidString
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? new.write(to: url, atomically: true, encoding: .utf8)
        return new
    }

    private func stamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    private func write(_ line: Data, on date: Date) {
        let today = String(stamp(date).prefix(10))
        if today != day {
            day = today
            used = nil
            full = false
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var total = used ?? size(of: files())
        if total + line.count > limit { total = trim(keeping: "\(today).jsonl", incoming: line.count) }
        if total + line.count > limit {
            guard !full else { return }
            full = true // passa um pouco do limite para o relatório saber que faltam dados
            let notice = Data("{\"ev\":\"log.full\",\"t\":\"\(stamp(date))\"}\n".utf8)
            add(notice, to: today)
            used = total + notice.count
            return
        }
        add(line, to: today)
        used = total + line.count
    }

    private func add(_ data: Data, to day: String) {
        let url = directory.appending(path: "\(day).jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return all.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func size(of files: [URL]) -> Int {
        files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func trim(keeping current: String, incoming: Int) -> Int {
        var all = files()
        var total = size(of: all)
        while total + incoming > limit, let oldest = all.first, oldest.lastPathComponent != current {
            total -= size(of: [oldest])
            try? FileManager.default.removeItem(at: oldest)
            all.removeFirst()
        }
        return total
    }
}
