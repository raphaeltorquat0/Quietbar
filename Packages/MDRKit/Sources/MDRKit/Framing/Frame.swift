/// Tipo de dado do frame MDR (`docs/PROTOCOL.md` §2).
public enum MDRDataType: Equatable, Hashable, Sendable {
    case data, ack, mdr, mdrNo2
    case other(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x00: self = .data
        case 0x01: self = .ack
        case 0x0C: self = .mdr
        case 0x0E: self = .mdrNo2
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .data: 0x00
        case .ack: 0x01
        case .mdr: 0x0C
        case .mdrNo2: 0x0E
        case .other(let v): v
        }
    }
}

/// Tabela de comandos: T1 viaja em DATA_MDR, T2 em DATA_MDR_NO2.
public enum MDRTable: Sendable, Hashable {
    case t1, t2

    public var dataType: MDRDataType { self == .t1 ? .mdr : .mdrNo2 }
}

public enum MDRFrameError: Error, Equatable, Sendable {
    case badMarker, badEscape, tooShort, badLength, badChecksum(expected: UInt8, got: UInt8)
}

public struct MDRFrame: Equatable, Sendable {
    public static let start: UInt8 = 0x3E
    public static let end: UInt8 = 0x3C
    static let escape: UInt8 = 0x3D

    public var type: MDRDataType
    public var seq: UInt8
    public var payload: [UInt8]

    public init(type: MDRDataType, seq: UInt8, payload: [UInt8] = []) {
        self.type = type
        self.seq = seq
        self.payload = payload
    }

    public static func ack(for seq: UInt8) -> MDRFrame { MDRFrame(type: .ack, seq: 1 &- seq) }

    public func encoded() -> [UInt8] {
        let n = UInt32(payload.count)
        var body: [UInt8] = [type.rawValue, seq, UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                             UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
        body += payload
        body.append(Self.checksum(body))
        return [Self.start] + Self.escaped(body) + [Self.end]
    }

    public init(decoding bytes: [UInt8]) throws(MDRFrameError) {
        guard bytes.first == Self.start, bytes.last == Self.end, bytes.count >= 2 else { throw .badMarker }
        let body = try Self.unescaped(bytes[1..<(bytes.count - 1)])
        guard body.count >= 7 else { throw .tooShort }
        let len = body[2...5].reduce(0) { $0 << 8 | Int($1) }
        guard len == body.count - 7 else { throw .badLength }
        let sum = Self.checksum(body.dropLast())
        guard sum == body.last! else { throw .badChecksum(expected: sum, got: body.last!) }
        self.init(type: MDRDataType(rawValue: body[0]), seq: body[1], payload: Array(body[6..<(body.count - 1)]))
    }

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt8 { bytes.reduce(0, &+) }

    static func escaped(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for b in bytes {
            if b == 0x3C || b == 0x3D || b == 0x3E { out += [escape, b - 0x10] } else { out.append(b) }
        }
        return out
    }

    static func unescaped(_ bytes: ArraySlice<UInt8>) throws(MDRFrameError) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var it = bytes.makeIterator()
        while let b = it.next() {
            guard b == escape else { out.append(b); continue }
            guard let n = it.next(), (0x2C...0x2E).contains(n) else { throw .badEscape }
            out.append(n + 0x10)
        }
        return out
    }
}

/// Junta bytes recebidos do RFCOMM (que podem chegar fatiados ou colados) em frames completos.
public struct MDRFrameParser: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Devolve os frames completos; frames corrompidos viram `.failure` e são descartados.
    public mutating func push(_ bytes: some Sequence<UInt8>) -> [Result<MDRFrame, MDRFrameError>] {
        buffer += bytes
        var out: [Result<MDRFrame, MDRFrameError>] = []
        while let s = buffer.firstIndex(of: MDRFrame.start) {
            guard let e = buffer[s...].firstIndex(of: MDRFrame.end) else {
                buffer.removeSubrange(..<s)
                return out
            }
            let raw = Array(buffer[s...e])
            buffer.removeSubrange(...e)
            do { out.append(.success(try MDRFrame(decoding: raw))) } catch { out.append(.failure(error)) }
        }
        buffer.removeAll()
        return out
    }
}
