import Foundation
import HeadphoneModel
import MDRTransport
import RealityKit

/// `mdr-cli bench`: mede o custo do que roda ao abrir o painel.
@MainActor func runBench() async throws {
    func time(_ label: String, _ body: () throws -> Void) rethrows {
        let t0 = Date()
        try body()
        print(String(format: "%-40@ %7.1f ms", label as NSString, Date().timeIntervalSince(t0) * 1000))
    }
    time("BluetoothDevices.paired()") { _ = BluetoothDevices.paired() }
    time("BluetoothDevices.paired() (2ª)") { _ = BluetoothDevices.paired() }
    time("HeadphoneAssembly.make (1ª, gera malha)") { _ = HeadphoneAssembly.make() }
    if #available(macOS 15, *) {
        var t0 = Date()
        await HeadphoneRealityKit.prewarm()
        print(String(format: "%-40@ %7.1f ms", "prewarm (IBL + protótipo, 1 vez)" as NSString, Date().timeIntervalSince(t0) * 1000))
        for n in 1...3 {
            t0 = Date()
            _ = try await HeadphoneRealityKit.make(rig: HeadphoneRig())
            print(String(format: "%-40@ %7.1f ms", "make (clone) \(n)ª abertura" as NSString, Date().timeIntervalSince(t0) * 1000))
        }
    }
}
