import MDRKit
import Testing
@testable import QuietAutomation

/// Fone falso: guarda o estado e registra cada escrita.
@MainActor
private final class FakeDevice: AutomationDevice {
    var state: Settings = [.soundMode: .mode(.off), .ambientLevel: .int(10), .equalizerPreset: .int(0), .macSound: .bool(false)]
    var available = true
    var writes: [Settings] = []
    var reads: [Bool] = []
    var failNext = false
    var inFlight = 0
    var maxInFlight = 0
    /// Segura a escrita até o teste soltar.
    var hold: CheckedContinuation<Void, Never>?
    var holding = false

    func read(headphone: Bool) async -> Settings? {
        reads.append(headphone)
        return available ? state : nil
    }

    func write(_ changes: Settings) async throws -> Settings {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if holding { await withCheckedContinuation { hold = $0 } }
        if failNext {
            failNext = false
            throw CancellationError()
        }
        writes.append(changes)
        state.merge(changes) { $1 }
        return changes
    }
}

private let call = Rule(id: "call", name: "Chamada", settings: [.soundMode: .mode(.noiseCanceling)])
private let focus = Rule(id: "focus", name: "Trabalho", settings: [.soundMode: .mode(.ambient), .ambientLevel: .int(5)])
private let app = Rule(id: "app", name: "Spotify", settings: [.soundMode: .mode(.ambient), .equalizerPreset: .int(0x10)])
private let wifi = Rule(id: "wifi", name: "Casa", settings: [.soundMode: .mode(.off), .ambientLevel: .int(3)])

@MainActor
private func settle() async { for _ in 0..<40 { await Task.yield() } }

@MainActor @Suite struct AutomationEngineTests {
    private let fone = FakeDevice()
    private var clock = Clock()
    private final class Clock { var now = ContinuousClock.now }

    private func make() -> AutomationEngine {
        let clock = clock
        return AutomationEngine(device: fone) { clock.now }
    }

    private var mode: Value? { fone.state[.soundMode] }

    @Test func precedenceIsCallFocusAppWifi() async {
        let e = make()
        e.set(.wifi, wifi)
        await settle()
        #expect(mode == .mode(.off))
        #expect(e.active == .rule(.wifi, name: "Casa"))
        e.set(.app, app)
        await settle()
        #expect(mode == .mode(.ambient))
        e.set(.call, call)
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        #expect(e.active == .rule(.call, name: "Chamada"))
        e.set(.focus, focus) // Foco entra por baixo da chamada
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.ambient))
        #expect(e.active == .rule(.focus, name: "Trabalho"))
    }

    @Test func eachRuleOnlyDecidesItsOwnFields() async {
        let e = make()
        e.set(.wifi, wifi)
        e.set(.call, call)
        await settle()
        #expect(fone.state[.ambientLevel] == .int(3)) // a chamada não define nível: fica o do Wi-Fi
        #expect(mode == .mode(.noiseCanceling))
    }

    @Test func endOfCallRestoresThePreviousState() async {
        fone.state[.soundMode] = .mode(.ambient)
        let e = make()
        e.set(.call, call)
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.ambient))
        #expect(e.active == nil)
        #expect(fone.writes.count == 2)
    }

    @Test func callOverAppProfileFallsBackToTheProfile() async {
        let e = make()
        e.set(.app, app)
        await settle()
        e.set(.call, call)
        await settle()
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.ambient))
        #expect(fone.state[.equalizerPreset] == .int(0x10))
        e.set(.app, nil)
        await settle()
        #expect(mode == .mode(.off)) // o padrão de antes do perfil, não o de antes da chamada
        #expect(fone.state[.equalizerPreset] == .int(0))
    }

    @Test func manualBeatsTheCallUntilTheContextChanges() async {
        let e = make()
        e.deviceReported(fone.state)
        e.set(.call, call)
        await settle()
        clock.now += .seconds(3)
        fone.state[.soundMode] = .mode(.ambient) // botão físico
        e.deviceReported(fone.state)
        #expect(e.active == .manual)
        e.set(.app, app) // sem mudança de modo: a chamada ainda vence, e o override acabou
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        #expect(e.active == .rule(.call, name: "Chamada"))
    }

    @Test func refreshingARuleIsNotAContextChange() async {
        let e = make()
        e.deviceReported(fone.state)
        e.set(.app, app)
        await settle()
        clock.now += .seconds(3)
        fone.state[.soundMode] = .mode(.noiseCanceling)
        e.deviceReported(fone.state)
        // App em foco sem perfil não chega ao motor como mudança, e o mesmo perfil de novo é a mesma regra.
        e.set(.app, app)
        await settle()
        #expect(e.manual[.soundMode] == .mode(.noiseCanceling))
        #expect(mode == .mode(.noiseCanceling))
        var edited = app
        edited.settings[.ambientLevel] = .int(7)
        e.set(.app, edited) // editar o perfil também não derruba o override
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        #expect(fone.state[.ambientLevel] == .int(7))
    }

    @Test func ownEchoIsNotManual() async {
        let e = make()
        e.deviceReported(fone.state)
        e.set(.call, call)
        await settle()
        e.deviceReported([.soundMode: .mode(.off)]) // retrato velho, de antes do eco
        #expect(e.manual.isEmpty)
        clock.now += .seconds(3)
        e.deviceReported(fone.state)
        #expect(e.manual.isEmpty)
    }

    @Test func restoredFieldIsNoLongerHeldByTheBaseline() async {
        fone.state[.soundMode] = .mode(.ambient)
        let e = make()
        e.set(.call, call)
        await settle()
        e.set(.call, nil)
        await settle()
        fone.state[.soundMode] = .mode(.off) // o usuário muda depois que tudo voltou
        e.set(.wifi, Rule(id: "x", name: "Rede", settings: [.ambientLevel: .int(4)]))
        await settle()
        #expect(mode == .mode(.off)) // um "anterior" velho não pode voltar
    }

    @Test func goingBackToTheRuleValueEndsTheOverride() async {
        let e = make()
        e.deviceReported(fone.state)
        e.set(.call, call)
        await settle()
        clock.now += .seconds(3)
        e.deviceReported([.soundMode: .mode(.ambient)]) // Speak-to-Chat entra
        #expect(e.active == .manual)
        e.deviceReported([.soundMode: .mode(.noiseCanceling)]) // e sai sozinho
        #expect(e.active == .rule(.call, name: "Chamada"))
    }

    @Test func manualWithoutRuleIsNotShownAndStaysAfterContextChange() async {
        let e = make()
        e.deviceReported(fone.state)
        fone.state[.soundMode] = .mode(.ambient)
        e.deviceReported(fone.state)
        #expect(e.active == nil)
        e.set(.wifi, Rule(id: "x", name: "Rede", settings: [.ambientLevel: .int(4)]))
        await settle()
        e.set(.wifi, nil)
        await settle()
        #expect(mode == .mode(.ambient))
    }

    @Test func stateChangedWithTheChannelClosedDoesNotBeatTheNextRule() async {
        let e = make()
        e.deviceReported(fone.state)
        e.deviceLost()
        fone.state[.soundMode] = .mode(.ambient) // apertou o botão com o canal solto
        e.deviceReported(fone.state)
        e.set(.call, call)
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.ambient))
    }

    @Test func applyManuallyWritesAndHoldsUntilContextChange() async {
        let e = make()
        e.set(.call, call)
        await settle()
        e.applyManually([.soundMode: .mode(.off), .ambientLevel: .int(2)])
        await settle()
        #expect(mode == .mode(.off))
        #expect(e.active == .manual)
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.off))
        #expect(fone.state[.ambientLevel] == .int(2))
    }

    @Test func writesNeverOverlapAndKeepOnlyTheNewestTarget() async {
        let e = make()
        fone.holding = true
        e.set(.wifi, wifi)
        await settle()
        e.set(.app, app)
        e.set(.call, call)
        e.set(.call, nil)
        e.set(.call, call)
        await settle()
        fone.holding = false
        fone.hold?.resume()
        await settle()
        #expect(fone.maxInFlight == 1)
        #expect(fone.writes.count == 2) // Wi-Fi em andamento + só o último alvo
        #expect(mode == .mode(.noiseCanceling))
    }

    @Test func unavailableHeadphoneRetriesWhenItComesBack() async {
        fone.available = false
        let e = make()
        e.set(.call, call)
        await settle()
        #expect(fone.writes.isEmpty)
        fone.available = true
        e.deviceAvailable()
        await settle()
        #expect(mode == .mode(.noiseCanceling))
    }

    @Test func availableWithNothingPendingDoesNotTouchTheHeadphone() async {
        let e = make()
        e.set(.call, call)
        await settle()
        let reads = fone.reads.count
        e.deviceAvailable()
        await settle()
        #expect(fone.reads.count == reads)
    }

    @Test func failedWriteRetriesAndKeepsTheBaseline() async {
        fone.state[.soundMode] = .mode(.ambient)
        let e = make()
        fone.failNext = true
        e.set(.call, call)
        await settle()
        #expect(fone.writes.isEmpty)
        e.deviceAvailable()
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.ambient))
    }

    @Test func noRulesNoChannel() async {
        let e = make()
        e.set(.app, nil)
        await settle()
        #expect(fone.reads.isEmpty)
        e.set(.app, Rule(id: "m", name: "Mac", settings: [.macSound: .bool(true)]))
        await settle()
        #expect(fone.reads == [false]) // só Som no Mac: não abre o canal com o fone
        #expect(fone.state[.macSound] == .bool(true))
    }

    @Test func fieldTheHeadphoneDoesNotHaveIsSkipped() async {
        fone.state[.equalizerPreset] = nil
        let e = make()
        e.set(.app, app)
        await settle()
        #expect(fone.writes == [[.soundMode: .mode(.ambient)]])
    }

    @Test func emptyRuleIsNotShownAsActive() {
        let e = make()
        e.set(.focus, Rule(id: "f", name: "Vazio", settings: [:]))
        #expect(e.active == nil)
    }

    @Test func forgettingTheDeviceDropsItsBaseline() async {
        fone.state[.soundMode] = .mode(.ambient)
        let e = make()
        e.set(.call, call)
        await settle()
        e.forgetDevice()
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.noiseCanceling)) // o "anterior" era do outro fone
    }
}
