import Foundation
import IOBluetooth
import Testing
@testable import MDRTransport

/// Sem IPC com o Bluetooth: nenhum destes testes pode abrir pedido de permissão.
private final class FakeDevice: IOBluetoothDevice {
    override var addressString: String! { "80-99-E7-9D-6C-FF" }
    override func register(forDisconnectNotification observer: Any!, selector inSelector: Selector!) -> IOBluetoothUserNotification! { nil }
}

/// O IOBluetooth chama os seletores, por isso os testes também entram pelo seletor.
private func deliver(_ selector: String, to watcher: BluetoothWatcher) {
    _ = watcher.perform(NSSelectorFromString(selector), with: IOBluetoothUserNotification(), with: FakeDevice())
}

@MainActor @Suite struct BluetoothWatcherTests {
    /// Visto no macOS 27: o aviso chega em `com.apple.bluetooth.iobluetooth.coordinatorQueue`.
    /// Com a classe isolada na main thread, o processo abortava (relatórios da 1.1.0 e da 1.3.0).
    @Test func eventFromABackgroundQueueArrivesOnTheMainThread() async {
        let watcher = BluetoothWatcher()
        let event: (String, Bool, Bool) = await withCheckedContinuation { c in
            watcher.onChange = { address, connected in c.resume(returning: (address, connected, Thread.isMainThread)) }
            nonisolated(unsafe) let w = watcher
            DispatchQueue.global().async { deliver("connected:device:", to: w) }
        }
        #expect(event.0 == "80:99:E7:9D:6C:FF")
        #expect(event.1)
        #expect(event.2)
    }

    /// Ao registrar, o IOBluetooth já avisa dos conectados, na mesma pilha. Isso roda dentro do `init` de
    /// `DeviceController.shared`: reagir ali reentrava o `shared` e abortava ("trying to lock recursively").
    @Test func eventNeverRunsInsideTheIOBluetoothCall() async {
        let watcher = BluetoothWatcher()
        var called = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            watcher.onChange = { _, _ in
                called = true
                c.resume()
            }
            deliver("connected:device:", to: watcher)
            #expect(!called)
        }
        #expect(called)
    }
}
