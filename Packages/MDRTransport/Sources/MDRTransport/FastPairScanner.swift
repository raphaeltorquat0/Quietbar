import CoreBluetooth
import Foundation

/// Um anúncio BLE visto pelo scanner.
public struct BLEAdvertisement: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rssi: Int
    /// Service data de `0xFE2C` (Google Fast Pair), se houver.
    public var fastPair: [UInt8]?
    public var manufacturer: [UInt8]?

    /// Em modo descobrível o Fast Pair anuncia só o model ID (3 bytes).
    public var fastPairModelID: String? {
        guard let fp = fastPair, fp.count == 3 else { return nil }
        return fp.map { String(format: "%02X", $0) }.joined()
    }

    public var summary: String {
        var s = "\(rssi) dBm  \(name)"
        if let fp = fastPair { s += "  FastPair=" + fp.map { String(format: "%02X", $0) }.joined(separator: " ") }
        if let id = fastPairModelID { s += " (model ID \(id))" }
        if let m = manufacturer { s += "  mfr=" + m.prefix(8).map { String(format: "%02X", $0) }.joined() }
        return s
    }
}

/// Procura anúncios BLE (Fast Pair `0xFE2C`) para investigar a detecção "fone por perto".
@MainActor public final class FastPairScanner: NSObject, CBCentralManagerDelegate {
    public private(set) var results: [UUID: BLEAdvertisement] = [:]
    public var onUpdate: ((BLEAdvertisement) -> Void)?
    public var onError: ((String) -> Void)?
    private var central: CBCentralManager?

    public override init() { super.init() }

    public func start() {
        results = [:]
        central = CBCentralManager(delegate: self, queue: .main)
    }

    public func stop() {
        central?.stopScan()
        central = nil
    }

    nonisolated public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let state = c.state
        MainActor.assumeIsolated {
            switch state {
            case .poweredOn: central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            case .unauthorized: onError?("Sem permissão de Bluetooth.")
            default: onError?("Bluetooth indisponível (estado \(state.rawValue)).")
            }
        }
    }

    nonisolated public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                           advertisementData ad: [String: Any], rssi: NSNumber) {
        let services = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let adv = BLEAdvertisement(id: p.identifier, name: (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?",
                                   rssi: rssi.intValue, fastPair: services[CBUUID(string: "FE2C")].map(Array.init),
                                   manufacturer: (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map(Array.init))
        MainActor.assumeIsolated {
            results[adv.id] = adv
            onUpdate?(adv)
        }
    }
}
