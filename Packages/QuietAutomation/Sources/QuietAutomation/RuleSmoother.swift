/// Suaviza o perfil por app: um app só vale depois de `enter`, e sair para um app sem perfil espera `exit`.
/// Cmd-Tab passando por vários apps não troca o modo, e uma ida rápida a outro app não desfaz o perfil.
@MainActor
public final class RuleSmoother {
    /// Desligado, repassa na hora.
    public var enabled = false
    public var enter: Duration
    public var exit: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let output: @MainActor (Rule?) -> Void
    private var current: Rule?
    private var pending: Task<Void, Never>?

    public init(enter: Duration, exit: Duration,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                output: @escaping @MainActor (Rule?) -> Void) {
        self.enter = enter
        self.exit = exit
        self.sleep = sleep
        self.output = output
    }

    public func update(_ rule: Rule?) {
        pending?.cancel()
        pending = nil
        guard rule != current else { return } // voltou ao que já valia: nada a escrever
        guard enabled else { return apply(rule) }
        pending = Task { [sleep, wait = rule == nil ? exit : enter] in
            do { try await sleep(wait) } catch { return }
            guard !Task.isCancelled else { return }
            apply(rule)
        }
    }

    private func apply(_ rule: Rule?) {
        current = rule
        output(rule)
    }
}
