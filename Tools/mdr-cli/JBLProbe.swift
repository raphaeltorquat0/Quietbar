import Foundation
import MDRTransport

/// `mdr-cli jbl-probe`: só leitura. Abre o GATT JBL, manda o HostType e GETs de `0x01`…`0x60`, e imprime
/// o hex cru. Serve para ver se o fone fala o Protocol4 e em que tags vêm a bateria e o modo.
@MainActor func runJBLProbe(name: String, seconds: Double) async throws {
    let channel = JBLChannel(name: name)
    channel.trace = { eprint("-- " + $0) }
    channel.traffic = { bytes, sent in
        let t = String(format: "%8.3f", Date().timeIntervalSince(startTime))
        eprint("\(t) \(sent ? ">>" : "<<") \(bytes.map { String(format: "%02x", $0) }.joined())")
    }
    _ = try await channel.open()
    // Um tag por GET: um tag desconhecido não derruba a resposta dos outros.
    for tag in Array(UInt16(0x01)...0x60) + [JBL.Tag.caseBattery] {
        try channel.read([tag])
        try await Task.sleep(for: .milliseconds(80))
    }
    try await Task.sleep(for: .seconds(seconds))
    await channel.close()
}

/// `mdr-cli jbl-set 49=ff 19=83`: um SET com esses TLVs (só tags de `JBL.writableTags`), depois relê os tags de
/// modo. Serve para medir o que o fone aceita, como a faixa do nível de Ambient Aware.
@MainActor func runJBLSet(name: String, pairs: [String]) async throws {
    let values: [(tag: UInt16, value: [UInt8])] = try pairs.map { pair in
        let parts = pair.split(separator: "=")
        guard parts.count == 2, let tag = UInt16(parts[0], radix: 16), let v = UInt8(parts[1], radix: 16) else {
            throw CLIError("par inválido: \(pair) (use tag=valor em hex, ex.: 19=83)")
        }
        return (tag, [v])
    }
    let channel = JBLChannel(name: name)
    channel.traffic = { bytes, sent in
        let t = String(format: "%8.3f", Date().timeIntervalSince(startTime))
        eprint("\(t) \(sent ? ">>" : "<<") \(bytes.map { String(format: "%02x", $0) }.joined())")
    }
    _ = try await channel.open()
    try channel.set(values)
    try await Task.sleep(for: .milliseconds(600))
    try channel.read([JBL.Tag.anc, JBL.Tag.ambientAware, JBL.Tag.talkThru, JBL.Tag.ambientSoundControl])
    try await Task.sleep(for: .seconds(1))
    await channel.close()
}
