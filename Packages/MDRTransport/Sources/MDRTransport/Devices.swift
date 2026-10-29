import IOBluetooth

public struct PairedDevice: Hashable, Sendable, Identifiable {
    public var name: String
    /// `AA:BB:CC:DD:EE:FF`
    public var address: String
    public var isConnected: Bool
    /// `true` se o registro SDP em cache anuncia o serviço Sony MDR v2.
    public var hasMDRService: Bool

    public var id: String { address }
}

@MainActor
public enum BluetoothDevices {
    public static func paired() -> [PairedDevice] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.map {
            PairedDevice(
                name: $0.name ?? "?",
                address: normalize($0.addressString ?? ""),
                isConnected: $0.isConnected(),
                hasMDRService: $0.getServiceRecord(for: MDRServiceUUID.v2SDP) != nil
            )
        }
    }

    /// Prefixos de nome das famílias Sony com MDR v2 (over-ear, earbuds, LinkBuds, ULT).
    static let sonyNamePrefixes = ["WH-", "WF-", "WI-", "LinkBuds", "ULT "]

    /// Nome de fone Sony conhecido (o registro SDP pode ainda não estar em cache).
    public static func looksLikeSony(_ name: String) -> Bool {
        sonyNamePrefixes.contains { name.hasPrefix($0) } || name.localizedCaseInsensitiveContains("WH-1000XM")
    }

    /// Fone Sony preferido: conectado e com serviço MDR, depois só com serviço, depois pelo nome.
    public static func preferredSony(among list: [PairedDevice] = paired()) -> PairedDevice? {
        let sony = list.filter { $0.hasMDRService || looksLikeSony($0.name) }
        return sony.first { $0.isConnected && $0.hasMDRService } ?? sony.first { $0.isConnected } ?? sony.first
    }

    public static func isConnected(_ address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() ?? false
    }

    /// Pede ao macOS a conexão Bluetooth (baseband) com um dispositivo pareado, sem bloquear a thread.
    /// Devolve `true` se conectou.
    public static func connect(_ address: String) async -> Bool {
        guard let d = IOBluetoothDevice(addressString: address) else { return false }
        if d.isConnected() { return true }
        return await withCheckedContinuation { c in
            let waiter = ConnectionWaiter { c.resume(returning: $0) }
            if d.openConnection(waiter) != kIOReturnSuccess { waiter.finish(false) }
        }
    }

    /// Fecha a conexão Bluetooth do dispositivo com o Mac.
    public static func disconnect(_ address: String) {
        _ = IOBluetoothDevice(addressString: address)?.closeConnection()
    }

    static func normalize(_ a: String) -> String { a.replacingOccurrences(of: "-", with: ":").uppercased() }
}

/// Alvo do `openConnection(_:)` assíncrono; se mantém vivo até o callback.
private final class ConnectionWaiter: NSObject, @unchecked Sendable {
    private var done: ((Bool) -> Void)?
    private var keepAlive: ConnectionWaiter?

    init(_ done: @escaping (Bool) -> Void) {
        self.done = done
        super.init()
        keepAlive = self
    }

    func finish(_ ok: Bool) {
        done?(ok)
        done = nil
        keepAlive = nil
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        finish(status == kIOReturnSuccess)
    }
}
