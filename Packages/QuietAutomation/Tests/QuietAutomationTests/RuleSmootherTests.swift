import Testing
@testable import QuietAutomation

@MainActor
private final class Timer {
    private var waiters: [(wait: Duration, resume: CheckedContinuation<Void, Never>)] = []

    func sleep(_ d: Duration) async { await withCheckedContinuation { waiters.append((d, $0)) } }

    /// Vence só a espera mais nova; as canceladas terminam sem efeito.
    func fireAll() -> [Duration] {
        let all = waiters
        waiters = []
        all.forEach { $0.resume.resume() }
        return all.map(\.wait)
    }
}

@MainActor
private func settle() async { for _ in 0..<20 { await Task.yield() } }

private let calc = Rule(id: "calc", name: "Calc", settings: [.ambientLevel: .int(1)])
private let dict = Rule(id: "dict", name: "Dict", settings: [.ambientLevel: .int(2)])

@MainActor @Suite struct RuleSmootherTests {
    private let timer = Timer()
    private let box = Box()
    private final class Box { var out: [String?] = [] }

    private func make(enabled: Bool = true) -> RuleSmoother {
        let timer = timer, box = box
        let s = RuleSmoother(enter: .milliseconds(400), exit: .seconds(6), sleep: { await timer.sleep($0) }) { box.out.append($0?.id) }
        s.enabled = enabled
        return s
    }

    @Test func offPassesStraightThrough() {
        let s = make(enabled: false)
        s.update(calc)
        s.update(nil)
        #expect(box.out == ["calc", nil])
    }

    @Test func enteringWaitsTheEntryDelay() async {
        let s = make()
        s.update(calc)
        await settle()
        #expect(box.out.isEmpty)
        #expect(timer.fireAll() == [.milliseconds(400)])
        await settle()
        #expect(box.out == ["calc"])
    }

    @Test func cmdTabThroughSeveralAppsAppliesOnlyTheLast() async {
        let s = make()
        s.update(calc)
        await settle()
        s.update(dict)
        await settle()
        s.update(nil)
        await settle()
        s.update(calc)
        await settle()
        _ = timer.fireAll()
        await settle()
        #expect(box.out == ["calc"])
    }

    @Test func leavingWaitsTheExitDelay() async {
        let s = make()
        s.update(calc)
        await settle()
        _ = timer.fireAll()
        await settle()
        s.update(nil)
        await settle()
        #expect(timer.fireAll() == [.seconds(6)])
        await settle()
        #expect(box.out == ["calc", nil])
    }

    @Test func comingBackDuringTheExitDelayWritesNothing() async {
        let s = make()
        s.update(calc)
        await settle()
        _ = timer.fireAll()
        await settle()
        s.update(nil)
        await settle()
        s.update(calc)
        await settle()
        #expect(timer.fireAll() == [.seconds(6)]) // só a espera cancelada
        await settle()
        #expect(box.out == ["calc"])
    }

    @Test func goingToAnotherProfileDoesNotWaitTheExit() async {
        let s = make()
        s.update(calc)
        await settle()
        _ = timer.fireAll()
        await settle()
        s.update(nil)
        await settle()
        s.update(dict)
        await settle()
        #expect(timer.fireAll().contains(.milliseconds(400)))
        await settle()
        #expect(box.out == ["calc", "dict"])
    }
}
