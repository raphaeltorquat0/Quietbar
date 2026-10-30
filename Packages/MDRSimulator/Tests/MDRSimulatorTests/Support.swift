import Foundation
import MDRKit
import MDRSession
@testable import MDRSimulator

func fastOptions() -> MDRSession.Options {
    var o = MDRSession.Options()
    o.ackTimeout = .milliseconds(80)
    o.backoff = .milliseconds(5)
    o.responseTimeout = .milliseconds(300)
    return o
}

func connected(_ profile: DeviceProfile) async throws -> (VirtualTransport, MDRSession) {
    let t = VirtualTransport(profile: profile)
    let s = MDRSession(channel: t, options: fastOptions())
    try await s.connect()
    return (t, s)
}

/// Espera o estado chegar: RET e NOTIFY vêm depois do ACK.
func eventually(_ s: MDRSession, _ test: (MDRDeviceState) -> Bool) async -> Bool {
    for _ in 0..<200 {
        if test(await s.state) { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")

    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".capture") }.map { String($0.dropLast(8)) }.sorted()
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appending(path: "\(name).capture"), encoding: .utf8)
    }

    /// (direção, bytes) de cada frame do arquivo.
    static func frames(_ name: String) throws -> [(String, [UInt8])] {
        try text(name).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let p = line.split(separator: " "), hex = Array(p[1])
            return (String(p[0]), stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0 + 1]), radix: 16)! })
        }
    }
}
