import Foundation
import IOBluetooth

/// Avisa quando um dispositivo Bluetooth conecta/desconecta (API de notificações do IOBluetooth).
/// O IOBluetooth chama os seletores numa fila própria e, ao registrar, avisa dos conectados na mesma pilha.
/// Por isso a classe não é isolada, e `onChange` sempre roda depois, na main thread.
public final class BluetoothWatcher: NSObject, @unchecked Sendable {
    public var onChange: (@MainActor (String, Bool) -> Void)?

    public func start() {
        IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        report(device, true)
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        report(device, false)
    }

    private func report(_ device: IOBluetoothDevice, _ connected: Bool) {
        let a = (device.addressString ?? "").replacingOccurrences(of: "-", with: ":").uppercased()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { onChange?(a, connected) }
        }
    }
}
