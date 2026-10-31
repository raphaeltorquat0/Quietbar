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
    var alreadyThere = false
    var check = DeviceReading.ModeCheck.notNeeded
    var modeUnread = false
    var heldMode: SoundMode?
    var inFlight = 0
    var maxInFlight = 0
    /// Segura a escrita até o teste soltar.
    var hold: CheckedContinuation<Void, Never>?
    var holding = false

    func read(headphone: Bool) async -> DeviceReading? {
        reads.append(headphone)
        guard available else { return nil }
        return DeviceReading(settings: modeUnread ? state.filter { $0.key != .soundMode } : state, check: check)
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
        if alreadyThere { return [:] }
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
        fone.state[.soundMode] = .mode(.ambient) // apertou o botão com o canal solto
        e.set(.call, call)
        await settle()
        #expect(mode == .mode(.noiseCanceling))
        e.set(.call, nil)
        await settle()
        #expect(mode == .mode(.ambient))
    }

    @Test func changeMadeWithTheChannelClosedIsManualWhenItReopens() async {
        let e = make()
        e.deviceReported(fone.state)
        e.set(.call, call)
        await settle()
        clock.now += .seconds(3)
        e.deviceReported(fone.state) // ainda aberto, igual à regra
        fone.state[.soundMode] = .mode(.ambient) // canal solto: nada chega
        e.deviceReported(fone.state) // canal reabriu
        #expect(e.active == .manual)
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

    @Test func logsTriggerDecisionWriteAndConfirmationWithLatency() async {
        let e = make()
        var events: [AutomationEvent] = []
        e.onEvent = { events.append($0) }
        e.set(.call, call)
        await settle()
        clock.now += .milliseconds(250)
        e.deviceReported(fone.state)
        #expect(events.map(\.kind) == [.trigger, .ruleStarted, .decision, .write, .confirm])
        #expect(events[0].trigger == "rule.call")
        #expect(events[3].fields == ["soundMode": "noiseCanceling"])
        #expect(events[4].rule == "call")
        #expect(events[4].latencyMs == 250)
        #expect(e.counters == AutomationCounters(writes: 1, confirmed: 1))
    }

    @Test func failedWriteIsCounted() async {
        let e = make()
        fone.failNext = true
        e.set(.call, call)
        await settle()
        #expect(e.counters == AutomationCounters(writes: 1, failed: 1))
    }

    @Test func noWriteNoCount() async {
        fone.state[.soundMode] = .mode(.noiseCanceling)
        let e = make()
        e.set(.call, call)
        await settle()
        #expect(e.counters.writes == 0)
    }

    @Test func noSetWhenTheHeadphoneAlreadyHasTheValue() async {
        let e = make()
        e.set(.call, call)
        await settle()
        #expect(fone.writes.count == 1)
        e.set(.focus, Rule(id: "f", name: "Foco", settings: [.soundMode: .mode(.ambient)]))
        await settle()
        #expect(fone.writes.count == 1) // a chamada vence e o fone já está nesse modo
        e.set(.focus, nil)
        await settle()
        #expect(fone.writes.count == 1)
    }

    @Test func valueThatArrivedBeforeTheSendIsNotAWrite() async {
        fone.alreadyThere = true
        let e = make()
        e.set(.call, call)
        await settle()
        #expect(e.counters.writes == 0)
        #expect(e.counters.redundantBlocked == 1)
        #expect(e.counters.confirmed == 0)
    }

    @Test func onlyAContextChangeCountsAsRuleStarted() async {
        let e = make()
        var started: [String] = []
        e.onEvent = { if $0.kind == .ruleStarted { started.append($0.trigger ?? "") } }
        e.set(.call, call)
        e.set(.call, Rule(id: "call", name: "Chamada", settings: [.soundMode: .mode(.off)])) // mesmo id: edição
        e.set(.call, nil)
        e.set(.focus, focus)
        #expect(started == ["call", "focus"])
    }

    // MARK: - Ler antes de escrever

    /// Fone em cancelamento pela chamada e canal solto: as próximas leituras vêm com o canal reaberto.
    private func heldByTheCall() async -> AutomationEngine {
        let e = make()
        e.set(.call, call)
        await settle()
        fone.check = .fresh
        return e
    }

    @Test func modeChangedWithTheChannelLooseKeepsTheOverride() async {
        let e = await heldByTheCall()
        fone.state[.soundMode] = .mode(.off)
        fone.writes = []
        e.set(.call, nil)
        e.set(.focus, focus)
        await settle()
        #expect(fone.writes.isEmpty) // nem o nível do ambiente, que a regra também mudaria
        #expect(e.active == .manual)
        #expect(e.counters.overridesKept == 1)
        #expect(fone.heldMode == .off)
    }

    @Test func overrideKeptEndsAtTheNextContextChange() async {
        let e = await heldByTheCall()
        fone.state[.soundMode] = .mode(.off)
        e.set(.focus, focus)
        e.set(.call, nil)
        await settle()
        fone.writes = []
        e.set(.focus, Rule(id: "outro", name: "Outro", settings: [.soundMode: .mode(.ambient)]))
        await settle()
        #expect(fone.writes.count == 1)
        #expect(fone.state[.soundMode] == .mode(.ambient))
        #expect(e.counters.overridesKept == 1)
        #expect(e.active == .rule(.focus, name: "Outro"))
    }

    @Test func sameModeAppliesNormally() async {
        let e = await heldByTheCall()
        var seen: [AutomationEvent.Kind] = []
        e.onEvent = { seen.append($0.kind) }
        e.set(.call, nil)
        e.set(.focus, focus)
        await settle()
        #expect(fone.state[.soundMode] == .mode(.ambient))
        #expect(e.active == .rule(.focus, name: "Trabalho"))
        #expect(e.counters.overridesKept == 0)
        #expect(seen.contains(.verified))
    }

    @Test func modeThatCouldNotBeReadStillAppliesTheRuleAndLogsIt() async {
        let e = await heldByTheCall()
        fone.state[.soundMode] = .mode(.off)
        fone.check = .failed
        fone.modeUnread = true
        var seen: [AutomationEvent.Kind] = []
        e.onEvent = { seen.append($0.kind) }
        e.set(.call, nil)
        e.set(.focus, focus)
        await settle()
        #expect(fone.state[.soundMode] == .mode(.ambient))
        #expect(e.counters.unverified == 1)
        #expect(e.counters.overridesKept == 0)
        #expect(seen.contains(.unverified))
    }

    @Test func restoreAfterTheRuleEndsIsAlsoHeldBack() async {
        let e = await heldByTheCall()
        fone.state[.soundMode] = .mode(.ambient)
        fone.writes = []
        e.set(.call, nil)
        await settle()
        #expect(fone.writes.isEmpty)
        #expect(e.active == .manual) // sem regra, mas é por isso que o modo não voltou
        #expect(fone.heldMode == nil)
        e.set(.focus, focus)
        await settle()
        e.set(.focus, nil)
        await settle()
        #expect(fone.state[.soundMode] == .mode(.ambient)) // o padrão agora é o que a pessoa escolheu
        #expect(e.active == nil)
    }

    @Test func modeChangedWithoutARuleDoesNotBlockTheNextRule() async {
        let e = await heldByTheCall()
        e.set(.call, nil)
        await settle()
        #expect(fone.heldMode == nil)
        fone.state[.soundMode] = .mode(.ambient)
        e.set(.focus, Rule(id: "f", name: "Foco", settings: [.soundMode: .mode(.noiseCanceling)]))
        await settle()
        #expect(fone.state[.soundMode] == .mode(.noiseCanceling))
        #expect(e.counters.overridesKept == 0)
    }

    @Test func overrideSeenWithTheChannelOpenEndsAtTheContextChangeAsBefore() async {
        let e = make()
        e.set(.focus, focus)
        await settle()
        clock.now += .seconds(3)
        fone.state[.soundMode] = .mode(.off)
        e.deviceReported(fone.state)
        #expect(fone.heldMode == .off)
        fone.check = .fresh
        e.set(.focus, Rule(id: "outro", name: "Outro", settings: [.soundMode: .mode(.ambient)]))
        await settle()
        #expect(fone.state[.soundMode] == .mode(.ambient))
        #expect(e.counters.overridesKept == 0)
    }

    @Test func channelAlreadyOpenDoesNotCompare() async {
        let e = make()
        e.set(.call, call)
        await settle()
        fone.state[.soundMode] = .mode(.off) // o RET do SET ainda não chegou
        e.set(.call, nil)
        e.set(.focus, focus)
        await settle()
        #expect(fone.state[.soundMode] == .mode(.ambient))
        #expect(e.counters.overridesKept == 0)
    }

    @Test func ruleThatFoundTheModeAlreadySetHoldsItToo() async {
        fone.state[.soundMode] = .mode(.noiseCanceling)
        let e = make()
        e.set(.call, call)
        await settle()
        #expect(fone.writes.isEmpty)
        #expect(fone.heldMode == .noiseCanceling)
    }

    @Test func heldModeSurvivesARestart() async {
        let first = await heldByTheCall()
        _ = first
        fone.state[.soundMode] = .mode(.off)
        fone.writes = []
        let e = make()
        e.set(.focus, focus)
        await settle()
        #expect(fone.writes.isEmpty)
        #expect(e.active == .manual)
    }

    @Test func unavailableDefersTheCheckToTheRetry() async {
        let e = await heldByTheCall()
        fone.state[.soundMode] = .mode(.off)
        fone.available = false
        fone.writes = []
        e.set(.call, nil)
        e.set(.focus, focus)
        await settle()
        #expect(e.counters.overridesKept == 0)
        fone.available = true
        e.deviceAvailable()
        await settle()
        #expect(fone.writes.isEmpty)
        #expect(e.counters.overridesKept == 1)
    }
}
