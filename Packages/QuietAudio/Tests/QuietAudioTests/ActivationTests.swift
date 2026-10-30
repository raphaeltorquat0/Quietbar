import Foundation
import Testing
@testable import QuietAudio

private let address = "80:99:E7:9D:6C:FF"
private let a2dp = OutputDevice(id: 145, uid: "80-99-E7-9D-6C-FF:output", name: "Fone", sampleRate: 48_000, channels: 2)
private let speakers = OutputDevice(id: 108, uid: "BuiltInSpeakerDevice", name: "Alto-falantes", sampleRate: 48_000, channels: 2)

@Suite struct ActivationMachineTests {
    private func ready() -> ActivationMachine {
        var m = ActivationMachine()
        _ = m.handle(.targetChanged(address: address))
        _ = m.handle(.outputChanged(a2dp))
        return m
    }

    @Test func matchesBluetoothAddressInTheUID() {
        #expect(a2dp.matches(bluetoothAddress: address))
        #expect(a2dp.matches(bluetoothAddress: address.lowercased()))
        #expect(!speakers.matches(bluetoothAddress: address))
        #expect(!a2dp.matches(bluetoothAddress: "80:99:E7:9D:6C:00"))
    }

    @Test func mountsOnlyWhenEnabledAndHeadphoneIsTheOutput() {
        var m = ActivationMachine()
        #expect(m.handle(.enabled(true)).isEmpty)
        #expect(m.phase == .waitingForOutput)
        #expect(m.handle(.targetChanged(address: address)).isEmpty)
        #expect(m.handle(.outputChanged(speakers)).isEmpty)
        #expect(m.handle(.outputChanged(a2dp)) == [.mount(a2dp)])
        #expect(m.phase == .arming)
    }

    @Test func nothingIsMutedUntilRealSignalArrives() {
        var m = ready()
        #expect(m.handle(.enabled(true)) == [.mount(a2dp)])
        #expect(m.phase == .arming)
        #expect(m.handle(.signalSeen) == [.arm])
        #expect(m.phase == .active)
        #expect(m.handle(.signalSeen).isEmpty)
    }

    @Test func outputChangeUnmountsAndComingBackMountsAgain() {
        var m = ready()
        _ = m.handle(.enabled(true))
        _ = m.handle(.signalSeen)
        #expect(m.handle(.outputChanged(speakers)) == [.unmount])
        #expect(m.phase == .waitingForOutput)
        #expect(m.handle(.outputChanged(a2dp)) == [.mount(a2dp)])
    }

    @Test func headphoneDisconnectUnmounts() {
        var m = ready()
        _ = m.handle(.enabled(true))
        _ = m.handle(.signalSeen)
        #expect(m.handle(.outputChanged(nil)) == [.unmount])
        #expect(m.phase == .waitingForOutput)
    }

    @Test func sampleRateChangeRemounts() {
        var m = ready()
        _ = m.handle(.enabled(true))
        _ = m.handle(.signalSeen)
        var d = a2dp
        d.sampleRate = 44_100
        #expect(m.handle(.outputChanged(d)) == [.unmount, .mount(d)])
        #expect(m.phase == .arming) // volta a provar o sinal antes de mutar
    }

    @Test func callModeStopsProcessing() {
        var m = ready()
        _ = m.handle(.enabled(true))
        _ = m.handle(.signalSeen)
        var hfp = a2dp
        hfp.sampleRate = 16_000
        hfp.channels = 1
        #expect(m.handle(.outputChanged(hfp)) == [.unmount])
        #expect(m.phase == .callMode)
        #expect(m.outputIsTarget)
        #expect(m.handle(.outputChanged(a2dp)) == [.mount(a2dp)])
    }

    @Test func repeatedNotificationsDoNotRemount() {
        var m = ready()
        _ = m.handle(.enabled(true))
        #expect(m.handle(.outputChanged(a2dp)).isEmpty)
    }

    @Test func failureLeavesAudioAloneAndWaitsForRetry() {
        var m = ready()
        _ = m.handle(.enabled(true))
        _ = m.handle(.signalSeen)
        #expect(m.handle(.stalled) == [.unmount])
        #expect(m.phase == .failed("O áudio do Mac parou de chegar ao processamento."))
        #expect(m.handle(.outputChanged(a2dp)).isEmpty)
        #expect(m.handle(.retry) == [.mount(a2dp)])
    }

    @Test func turningOffUnmountsFromAnyPhase() {
        var m = ready()
        _ = m.handle(.enabled(true))
        #expect(m.handle(.enabled(false)) == [.unmount])
        #expect(m.phase == .off)
    }

    @Test func silenceDropsTheMuteAndSignalArmsAgain() {
        var m = ready()
        _ = m.handle(.enabled(true))
        _ = m.handle(.signalSeen)
        #expect(m.handle(.silence) == [.disarm])
        #expect(m.phase == .arming)
        #expect(m.handle(.signalSeen) == [.arm])
    }
}

private final class FakeBackend: AudioBackend {
    var onFailure: (@MainActor @Sendable (String) -> Void)?
    var onOutputChange: (@MainActor @Sendable () -> Void)?
    var output: OutputDevice? = a2dp
    var commands: [AudioCommand] = []
    func perform(_ command: AudioCommand) { commands.append(command) }
    func currentOutput() -> OutputDevice? { output }
}

@Suite struct DefaultStateTests {
    /// Instalação nova e update da 1.3.0 partem daqui: sem ligar, nada monta, mesmo com o fone na saída.
    @Test func staysOffUntilEnabled() {
        var m = ActivationMachine()
        #expect(m.handle(.targetChanged(address: address)).isEmpty)
        #expect(m.handle(.outputChanged(a2dp)).isEmpty)
        #expect(m.phase == .off)
        #expect(m.mounted == nil)
    }
}

@MainActor @Suite struct AudioEngineTests {
    private func running() -> (AudioEngine, FakeBackend) {
        let b = FakeBackend()
        let e = AudioEngine(backend: b, chain: DSPChain())
        e.setTarget(address: address)
        e.refreshOutput()
        e.setEnabled(true)
        e.chain.reset(sampleRate: 48_000) // o que o backend real faz ao montar
        return (e, b)
    }

    private func feed(_ e: AudioEngine, _ value: Float, frames: Int = 4800) {
        var l = [Float](repeating: value, count: frames), r = l
        e.chain.process(left: &l, right: &r)
    }

    @Test func armsOnFirstSignal() {
        let (e, b) = running()
        feed(e, 0)
        e.tick()
        #expect(e.phase == .arming)
        #expect(b.commands == [.mount(a2dp)])
        feed(e, 0.1)
        e.tick()
        #expect(e.phase == .active)
        #expect(b.commands == [.mount(a2dp), .arm])
    }

    @Test func testToneNeverReleasesTheMute() {
        let (e, b) = running()
        e.setTone(true)
        feed(e, 0)
        e.tick()
        #expect(e.phase == .arming)
        #expect(!b.commands.contains(.arm))
        e.setTone(false)
    }

    @Test func longDigitalSilenceDisarmsThenResumes() {
        let (e, b) = running()
        feed(e, 0.1)
        e.tick()
        feed(e, 0, frames: 48_000 * 6)
        e.tick()
        #expect(e.phase == .arming)
        #expect(b.commands.last == .disarm)
        feed(e, 0)
        e.tick()
        #expect(e.phase == .arming, "silêncio velho não conta como sinal novo")
        feed(e, 0.1)
        e.tick()
        #expect(e.phase == .active)
    }

    @Test func stalledRenderGivesTheAudioBack() {
        let (e, b) = running()
        feed(e, 0.1)
        e.tick()
        for _ in 0..<AudioEngine.stallTicks { e.tick() }
        #expect(b.commands.last == .unmount)
        guard case .failed = e.phase else { Issue.record("deveria ter falhado"); return }
    }

    /// Nada tocando: o aggregate nem começa a rodar. Isso não é falha, e nada é mutado.
    @Test func waitsForAudioForeverWithoutFailing() {
        let (e, b) = running()
        for _ in 0..<2_000 { e.tick() }
        #expect(e.phase == .arming)
        #expect(b.commands == [.mount(a2dp)])
    }

    @Test func backendFailureUnmounts() async {
        let (e, b) = running()
        await b.onFailure?("tap")
        #expect(e.phase == .failed("tap"))
        #expect(b.commands.last == .unmount)
    }

    @Test func outputChangeFromTheSystemIsFollowed() async {
        let (e, b) = running()
        #expect(e.outputIsTarget)
        b.output = speakers
        await b.onOutputChange?()
        #expect(!e.outputIsTarget)
        #expect(e.phase == .waitingForOutput)
        #expect(b.commands.last == .unmount)
    }
}
