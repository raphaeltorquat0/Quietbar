import MDRKit

extension CapturedFrames {
    struct Entry: Sendable {
        let direction: String
        let frame: MDRFrame
        let raw: [UInt8]
    }

    /// Frames de uma fixture, na ordem da captura.
    static func frames(_ name: String) -> [Entry] {
        (all[name] ?? []).compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { return nil }
            let hex = Array(parts[1])
            let raw = stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(String(hex[$0...$0 + 1]), radix: 16) }
            return (try? MDRFrame(decoding: raw)).map { Entry(direction: String(parts[0]), frame: $0, raw: raw) }
        }
    }
}
