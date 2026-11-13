import CoreAudio
import IOBluetooth

public struct PairedDevice: Hashable, Sendable, Identifiable {
    public var name: String
    /// `AA:BB:CC:DD:EE:FF`
    public var address: String
    public var isConnected: Bool
    /// `true` se o registro SDP em cache anuncia o serviço Sony MDR v2.
    public var hasMDRService: Bool

    public var id: String { address }
    /// JBL fala o protocolo BLE da Harman, não MDR (`JBL.swift`).
    public var isJBL: Bool { name.hasPrefix("JBL ") }
}

@MainActor
public enum BluetoothDevices {
    public static func paired() -> [PairedDevice] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let audio = audioAddresses()
        var seen = Set<String>()
        // Fone de modo duplo (o JBL) vem duas vezes, uma por transporte, com o mesmo endereço.
        return devices.compactMap {
            let address = normalize($0.addressString ?? "")
            guard seen.insert(address).inserted else { return nil }
            return PairedDevice(
                name: $0.name ?? "?",
                address: address,
                isConnected: $0.isConnected() || audio.contains(address),
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

    /// Fone que o app controla: Sony com serviço MDR ou pelo nome, ou JBL.
    public static func isSupported(_ d: PairedDevice) -> Bool { d.hasMDRService || looksLikeSony(d.name) || d.isJBL }

    /// Fone preferido: conectado e com serviço MDR, depois qualquer suportado conectado, depois o primeiro.
    public static func preferredDevice(among list: [PairedDevice] = paired()) -> PairedDevice? {
        let ok = list.filter(isSupported)
        return ok.first { $0.isConnected && $0.hasMDRService } ?? ok.first { $0.isConnected } ?? ok.first
    }

    public static func isConnected(_ address: String) -> Bool {
        IOBluetoothDevice(addressString: address)?.isConnected() == true || audioAddresses().contains(normalize(address))
    }

    /// Endereços com saída ou entrada de áudio Bluetooth no Core Audio (UID `38-D5-18-CE-58-59:output`).
    /// No macOS 27 o IOBluetooth responde desconectado para o JBL Live Beam 4 enquanto ele toca; o Core Audio não erra.
    static func audioAddresses() -> Set<String> {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return [] }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return Set(ids.compactMap { id -> String? in
            var uid: Unmanaged<CFString>?
            var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &n, &uid) == noErr,
                  let u = uid?.takeRetainedValue() as String?, let head = u.split(separator: ":").first,
                  head.count == 17 else { return nil }
            return normalize(String(head))
        })
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
