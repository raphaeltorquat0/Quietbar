import Foundation
import Testing
@testable import QuietTelemetry

private let utc = TimeZone(identifier: "UTC")!
private let monday = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

private final class Clock: @unchecked Sendable {
    var now = monday
}

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "dogfood-\(UUID().uuidString)")
}

private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
}

private func lines(_ url: URL) -> [[String: Any]] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    }
}

@Test func umArquivoPorDiaSemCamposNulos() {
    let dir = folder(), clock = Clock()
    let log = DogfoodLog(directory: dir, now: { clock.now }, timeZone: utc)
    log.append("a", ["x": 1, "vazio": nil])
    clock.now += 86400
    log.append("b")
    log.flush()
    #expect(names(dir) == ["2026-09-21.jsonl", "2026-09-22.jsonl"])
    let first = lines(dir.appending(path: "2026-09-21.jsonl"))[0]
    #expect(first["ev"] as? String == "a")
    #expect(first["x"] as? Int == 1)
    #expect(first["vazio"] == nil)
    #expect((first["t"] as? String)?.hasPrefix("2026-09-21T") == true)
}

@Test func passandoDoLimiteSaemOsDiasMaisAntigos() {
    let dir = folder(), clock = Clock()
    let log = DogfoodLog(directory: dir, limit: 350, now: { clock.now }, timeZone: utc)
    for _ in 0..<3 {
        log.append("dia", ["texto": String(repeating: "x", count: 100)])
        clock.now += 86400
    }
    log.flush()
    #expect(names(dir) == ["2026-09-22.jsonl", "2026-09-23.jsonl"])
}

@Test func soHojeNoLimiteParaEAvisaUmaVez() {
    let dir = folder()
    let log = DogfoodLog(directory: dir, limit: 200, now: { monday }, timeZone: utc)
    for _ in 0..<5 { log.append("dia", ["texto": String(repeating: "x", count: 100)]) }
    log.flush()
    let all = lines(dir.appending(path: "2026-09-21.jsonl"))
    #expect(all.count == 2)
    #expect(all.last?["ev"] as? String == "log.full")
}

@Test func hashEhEstavelESemOTexto() {
    let dir = folder()
    let a = DogfoodLog(directory: dir), b = DogfoodLog(directory: dir)
    #expect(a.hash("MinhaRede") == b.hash("MinhaRede"))
    #expect(a.hash("MinhaRede") != a.hash("OutraRede"))
    #expect(a.hash("MinhaRede") != DogfoodLog(directory: folder()).hash("MinhaRede"))
    #expect(!a.hash("MinhaRede").contains("Minha"))
}
