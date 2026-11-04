/// Só repassa uma mudança depois que ela se mantém por `delay`; um pico mais curto é descartado.
@MainActor
public final class Debouncer {
    public var delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let output: @MainActor (Bool) -> Void
    private var stable = false
    private var wanted = false
    private var pending: Task<Void, Never>?

    /// `sleep` é injetado para os testes controlarem o tempo.
    public init(delay: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                output: @escaping @MainActor (Bool) -> Void) {
        self.delay = delay
        self.sleep = sleep
        self.output = output
    }

    public func input(_ value: Bool) {
        guard value != wanted else { return }
        wanted = value
        pending?.cancel()
        pending = nil
        guard value != stable else { return } // voltou ao que já valia: o pico acabou
        pending = Task { [delay, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            stable = value
            output(value)
        }
    }

    /// Volta ao estado de repouso sem avisar: o gatilho foi desligado.
    public func reset() {
        pending?.cancel()
        pending = nil
        stable = false
        wanted = false
    }
}
