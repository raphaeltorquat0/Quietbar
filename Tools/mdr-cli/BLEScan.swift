import Foundation
import MDRTransport

/// `mdr-cli ble-scan`: imprime cada anunciante uma vez (Fast Pair e fones; `--all` para todos).
@MainActor func runBLEScan(seconds: Double, showAll: Bool) async throws {
    let scanner = FastPairScanner()
    var printed = Set<UUID>()
    scanner.onError = { eprint($0) }
    scanner.onUpdate = { a in
        guard a.fastPair != nil || showAll || a.name.localizedCaseInsensitiveContains("WH-"), printed.insert(a.id).inserted else { return }
        print(a.summary)
    }
    scanner.start()
    eprint("escutando anúncios BLE por \(Int(seconds)) s (ponha o fone em modo de pareamento)…")
    try await Task.sleep(for: .seconds(seconds))
    scanner.stop()
    eprint("anunciantes Fast Pair (0xFE2C): \(scanner.results.values.filter { $0.fastPair != nil }.count)")
}
