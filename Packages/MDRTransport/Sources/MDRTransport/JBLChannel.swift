import CoreBluetooth
import Foundation
import IOBluetooth
import MDRKit

public enum JBLChannelError: Error, LocalizedError, Sendable {
    case bluetoothUnavailable(Int)
    case notFound(String)
    case serviceNotFound
    case notOpen
    case notAllowed

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let s): "Bluetooth indisponível (estado \(s))"
        case .notFound(let n): "\(n) não apareceu no Bluetooth LE. Ele está ligado e fora do estojo?"
        case .serviceNotFound: "O fone não expõe o serviço de controle JBL (Protocol4)"
        case .notOpen: "Canal JBL fechado"
        case .notAllowed: "Tag fora da lista de escrita permitida (JBL.writableTags)"
        }
    }
}

/// `MDRChannel` até um JBL por GATT. Por dentro, o `JBLBridge` responde em MDR, e a sessão não sabe a diferença.
/// Callbacks do CoreBluetooth chegam na main queue, como os do IOBluetooth no `RFCOMMChannel`.
@MainActor
public final class JBLChannel: NSObject, MDRChannel {
    /// Nome do pareamento Classic. O CoreBluetooth não mostra o MAC, então o periférico LE é achado pelo nome.
    public let name: String
    /// Nome Bluetooth do Mac: o fone confere o CRC dele no modo de segurança 3 (`JBL.hostNameCRC`).
    public let hostName: String
    private let openTimeout: Duration
    /// Etapas da conexão, para `mdr-cli --trace`.
    public var trace: ((String) -> Void)?
    /// Bytes JBL crus: `true` = enviado pelo Mac.
    public var traffic: (@MainActor ([UInt8], Bool) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var rawChar: CBCharacteristic?
    private var hostCRCEchoed = false
    private var step: CheckedContinuation<Void, Error>?
    private var incoming: AsyncStream<[UInt8]>.Continuation?
    private var bridge: JBLBridge
    private var parser = MDRFrameParser()
    private var reassembler = JBL.Reassembler()

    private static let service = CBUUID(string: JBL.service)

    public init(name: String, hostName: String? = nil, openTimeout: Duration = .seconds(10)) {
        self.name = name
        self.hostName = hostName ?? IOBluetoothHostController.default()?.nameAsString() ?? Host.current().localizedName ?? ""
        self.openTimeout = openTimeout
        bridge = JBLBridge(modelName: name)
    }

    public func open() async throws -> AsyncStream<[UInt8]> {
        await close()
        bridge = JBLBridge(modelName: name)
        parser = MDRFrameParser()
        reassembler = JBL.Reassembler()
        let timeout = Task { [openTimeout, name] in
            try? await Task.sleep(for: openTimeout)
            self.fail(JBLChannelError.notFound(name))
        }
        defer { timeout.cancel() }

        if central?.state != .poweredOn {
            try await wait { self.central = CBCentralManager(delegate: self, queue: .main) }
        }
        guard let central else { throw JBLChannelError.notOpen }
        let known = central.retrieveConnectedPeripherals(withServices: [Self.service])
        trace?("LE já conectados com o serviço: \(known.map { $0.name ?? "?" })")
        if let p = pick(known) {
            peripheral = p
        } else {
            // O Live Beam 4 anuncia só o nome, sem o UUID do serviço: filtro pelo nome em `didDiscover`.
            trace?("procurando anúncios do JBL…")
            try await wait { central.scanForPeripherals(withServices: nil) }
            central.stopScan()
        }
        guard let p = peripheral else { throw JBLChannelError.notFound(name) }
        p.delegate = self
        try await wait { central.connect(p) }
        trace?("LE conectado: \(p.name ?? "?")")
        try await wait { p.discoverServices([Self.service]) }
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { throw JBLChannelError.serviceNotFound }
        try await wait { p.discoverCharacteristics([JBL.write, JBL.notify, JBL.raw].map { CBUUID(string: $0) }, for: s) }
        writeChar = s.characteristics?.first { $0.uuid == CBUUID(string: JBL.write) }
        rawChar = s.characteristics?.first { $0.uuid == CBUUID(string: JBL.raw) }
        guard writeChar != nil, let n = s.characteristics?.first(where: { $0.uuid == CBUUID(string: JBL.notify) }) else {
            throw JBLChannelError.serviceNotFound
        }
        // Modo de segurança 3 (Live Beam 4): o app liga o notify do canal raw, manda o CRC do nome do host
        // por ele e espera o eco até 1 s antes de seguir, com ou sem eco (`BleDevice`, app 5.38.2).
        if let raw = rawChar {
            try await wait { p.setNotifyValue(true, for: raw) }
            hostCRCEchoed = false
            trace?(String(format: "HostNameCRC de \"%@\": %04X", hostName, JBL.hostNameCRC(hostName)))
            send(JBL.setHostNameCRC(hostName), on: raw)
            await pause(upTo: .seconds(1)) { self.hostCRCEchoed }
            trace?(hostCRCEchoed ? "HostNameCRC confirmado pelo fone" : "HostNameCRC sem eco; seguindo")
        }
        try await wait { p.setNotifyValue(true, for: n) }
        trace?("notify ligado")

        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        incoming = continuation
        for f in JBLBridge.handshake { send(f) }
        // As funções anunciadas à sessão dependem do modelo, que vem no ProductID.
        await pause(upTo: .seconds(2)) { self.bridge.productID != nil }
        trace?(bridge.productID.map { String(format: "ProductID %04X%@", $0, bridge.isLiveTws4 ? " (LiveTws4)" : "") } ?? "sem ProductID")
        return stream
    }

    private func pause(upTo limit: Duration, until done: () -> Bool) async {
        let end = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard incoming != nil else { throw JBLChannelError.notOpen }
        for case .success(let frame) in parser.push(bytes) {
            let out = bridge.receive(frame)
            for f in out.mdr { incoming?.yield(f.encoded()) }
            for f in out.jbl { send(f) }
        }
    }

    /// Só leitura, para o `mdr-cli jbl-probe`.
    public func read(_ tags: [UInt16]) throws {
        guard incoming != nil else { throw JBLChannelError.notOpen }
        send(JBL.get(tags))
    }

    /// SET cru, para o `mdr-cli jbl-set`. Só tags de `JBL.writableTags`: o resto é recusado.
    public func set(_ values: [(tag: UInt16, value: [UInt8])]) throws {
        guard incoming != nil else { throw JBLChannelError.notOpen }
        guard let f = JBL.set(values) else { throw JBLChannelError.notAllowed }
        send(f)
    }

    /// Solta só o link LE do app. O áudio é Classic e continua.
    public func close() async {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil
        writeChar = nil
        rawChar = nil
        incoming?.finish()
        incoming = nil
        fail(JBLChannelError.notOpen)
    }

    private func send(_ f: JBL.Frame, on characteristic: CBCharacteristic? = nil) {
        guard let p = peripheral, let c = characteristic ?? writeChar else { return }
        traffic?(f.encoded, true)
        p.writeValue(Data(f.encoded), for: c, type: .withResponse)
    }

    private func pick(_ list: [CBPeripheral]) -> CBPeripheral? {
        list.first { matches($0.name) } ?? list.first
    }

    /// O nome LE costuma ser o Classic com sufixo (`-LE`) ou o contrário.
    private func matches(_ le: String?) -> Bool {
        guard let le else { return false }
        return le.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(le)
    }

    private func wait(_ start: () -> Void) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            step = c
            start()
        }
    }

    private func advance() {
        step?.resume()
        step = nil
    }

    private func fail(_ e: Error) {
        step?.resume(throwing: e)
        step = nil
    }

    private func received(_ bytes: [UInt8]) {
        traffic?(bytes, false)
        guard let f = reassembler.push(bytes) else { return }
        if JBL.values(f.payload)?[JBL.Tag.hostNameCRC] != nil { hostCRCEchoed = true }
        for m in bridge.receive(f) { incoming?.yield(m.encoded()) }
    }

    private func dropped() {
        peripheral = nil
        writeChar = nil
        rawChar = nil
        incoming?.finish()
        incoming = nil
        fail(JBLChannelError.notOpen)
    }
}

extension JBLChannel: CBCentralManagerDelegate, CBPeripheralDelegate {
    public nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let state = c.state
        MainActor.assumeIsolated {
            switch state {
            case .poweredOn: advance()
            case .unknown, .resetting: break
            default: fail(JBLChannelError.bluetoothUnavailable(state.rawValue))
            }
        }
    }

    public nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                           advertisementData ad: [String: Any], rssi: NSNumber) {
        let advertised = ad[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        // A central entrega na main queue: o periférico não cruza de thread.
        nonisolated(unsafe) let found = p
        MainActor.assumeIsolated {
            trace?("anúncio: \(advertised ?? "?")")
            guard matches(advertised) else { return }
            peripheral = found
            advance()
        }
    }

    public nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { advance() }
    }

    public nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "?"
        MainActor.assumeIsolated {
            trace?("LE: falha ao conectar: \(message)")
            fail(JBLChannelError.notOpen)
        }
    }

    public nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let id = p.identifier
        MainActor.assumeIsolated {
            guard id == peripheral?.identifier else { return }
            trace?("LE: desconectado pelo fone")
            dropped()
        }
    }

    public nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let failed = error != nil
        MainActor.assumeIsolated { failed ? fail(JBLChannelError.serviceNotFound) : advance() }
    }

    public nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let failed = error != nil
        MainActor.assumeIsolated { failed ? fail(JBLChannelError.serviceNotFound) : advance() }
    }

    public nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated {
            if let message { trace?("notify: \(message)") }
            message == nil ? advance() : fail(JBLChannelError.serviceNotFound)
        }
    }

    public nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        let bytes = Array(data)
        MainActor.assumeIsolated { received(bytes) }
    }

    public nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard let message = error?.localizedDescription else { return }
        MainActor.assumeIsolated { trace?("escrita JBL recusada: \(message)") }
    }
}
