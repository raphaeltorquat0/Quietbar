import Foundation

/// O canal não abriu a tempo. Só este erro justifica tentar de novo (DECISIONS.md #88).
public struct MDRChannelOpenTimeout: Error, LocalizedError, Sendable {
    public init() {}
    public var errorDescription: String? { "O fone não respondeu a tempo ao abrir o canal" }
}

/// Canal de bytes até o fone (RFCOMM no app, fake nos testes).
public protocol MDRChannel: AnyObject, Sendable {
    /// Abre o canal. O stream devolvido termina quando o canal fecha (pelo fone ou por `close()`).
    func open() async throws -> AsyncStream<[UInt8]>
    func write(_ bytes: [UInt8]) async throws
    func close() async
}
