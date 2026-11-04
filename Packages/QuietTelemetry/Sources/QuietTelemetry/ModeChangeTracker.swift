import Foundation

/// Atribui cada mudança de modo informada pelo fone. Os SETs só anunciam a intenção: o que conta é a mudança,
/// então pedir o modo atual não soma nada. Sem intenção recente, foi algo fora do app: o botão físico, na prática.
public struct ModeChangeTracker: Sendable {
    public enum Origin: Sendable, Equatable {
        case engine
        case user(ModeSource)
    }

    /// O RET de um SET costuma chegar em menos de 100 ms. Passou disso, a intenção não explica a mudança.
    static let window: TimeInterval = 3

    private var mode: String?
    private var expected: (origin: Origin, at: Date)?

    public init() {}

    public mutating func expect(_ origin: Origin, at now: Date) { expected = (origin, now) }

    /// A fonte, se a mudança deve contar. Sem modo anterior, o canal acabou de abrir e não há o que comparar.
    public mutating func observe(_ mode: String?, at now: Date) -> ModeSource? {
        defer { self.mode = mode }
        guard let old = self.mode, let mode, old != mode else { return nil }
        defer { expected = nil }
        guard let expected, now.timeIntervalSince(expected.at) <= Self.window else { return .externalChange }
        if case .user(let source) = expected.origin { return source }
        return nil
    }
}
