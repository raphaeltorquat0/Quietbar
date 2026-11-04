import Testing
@testable import QuietAutomation

/// Tempo manual: cada `sleep` fica parado até o teste liberar.
@MainActor
private final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep() async { await withCheckedContinuation { waiters.append($0) } }

    var count: Int { waiters.count }

    func fire() { waiters.removeFirst().resume() }
}

@MainActor
private func settle() async { for _ in 0..<20 { await Task.yield() } }

@MainActor @Suite struct DebouncerTests {
    private let gate = Gate()
    private var out: [Bool] { box.values }
    private let box = Box()
    private final class Box { var values: [Bool] = [] }

    private func make() -> Debouncer {
        let gate = gate, box = box
        return Debouncer(delay: .seconds(3), sleep: { _ in await gate.sleep() }) { box.values.append($0) }
    }

    @Test func holdsTheChangeUntilTheDelayEnds() async {
        let d = make()
        d.input(true)
        await settle()
        #expect(out.isEmpty)
        gate.fire()
        await settle()
        #expect(out == [true])
    }

    @Test func shortPeakNeverComesOut() async {
        let d = make()
        d.input(true)
        await settle()
        d.input(false) // o microfone abriu e fechou antes do fim da espera
        await settle()
        gate.fire() // a espera antiga termina depois do cancelamento
        await settle()
        #expect(out.isEmpty)
    }

    @Test func endOfCallAlsoWaits() async {
        let d = make()
        d.input(true)
        await settle()
        gate.fire()
        await settle()
        d.input(false)
        await settle()
        #expect(out == [true]) // queda curta do microfone no meio da chamada
        d.input(true)
        await settle()
        gate.fire()
        await settle()
        #expect(out == [true])
    }

    @Test func repeatedInputDoesNotRestartTheWait() async {
        let d = make()
        d.input(true)
        d.input(true)
        d.input(true)
        await settle()
        #expect(gate.count == 1)
        gate.fire()
        await settle()
        #expect(out == [true])
    }

    @Test func resetForgetsEverything() async {
        let d = make()
        d.input(true)
        await settle()
        gate.fire()
        await settle()
        d.reset()
        d.input(true)
        await settle()
        gate.fire()
        await settle()
        #expect(out == [true, true])
    }
}
