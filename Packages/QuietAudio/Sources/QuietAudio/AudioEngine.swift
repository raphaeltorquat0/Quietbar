import Foundation
import Observation

/// Liga a máquina de ativação ao backend e vigia a cadeia. Tudo aqui é main thread; o render nem sabe que existe.
@MainActor @Observable
public final class AudioEngine {
    public private(set) var phase = AudioPhase.off
    public private(set) var device: OutputDevice?
    /// O fone controlado é a saída padrão agora (é o que mostra o bloco no painel).
    public private(set) var outputIsTarget = false
    public private(set) var outputLevel: Float = 0
    public private(set) var load: Float = 0
    public private(set) var latency: Float = 0
    public private(set) var bypass = false
    public private(set) var toneOn = false

    public let chain: DSPChain
    @ObservationIgnored private let backend: AudioBackend
    @ObservationIgnored private var machine = ActivationMachine()
    @ObservationIgnored private var curve = EQCurve(name: "", filters: [])
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastFrames: UInt64 = 0
    @ObservationIgnored private var signalMark: UInt64 = 0
    @ObservationIgnored private var stuckTicks = 0
    @ObservationIgnored private var retriesLeft = maxRetries

    static let tickSeconds = 0.05
    /// Silêncio digital com o original mudo: volta ao estado sem mudo, porque pode ser a tap que parou
    /// de entregar. Limita a 5 s o pior caso de ficar sem som, e na próxima música rearma sozinho.
    static let silenceSeconds = 5.0
    /// Só vale com o original mudo. Antes disso, zero quadros é o normal: o aggregate com tap só
    /// começa a rodar quando algum app toca no dispositivo.
    static let stallTicks = 30 // 1,5 s
    static let maxRetries = 3
    static let retrySeconds = 5.0

    public init(backend: AudioBackend, chain: DSPChain) {
        self.backend = backend
        self.chain = chain
        backend.onFailure = { [weak self] in self?.send(.failed($0)) }
        backend.onOutputChange = { [weak self] in self?.refreshOutput() }
    }

    public func setEnabled(_ on: Bool) {
        if on { retriesLeft = Self.maxRetries }
        send(.enabled(on))
    }

    public func setTarget(address: String?) { send(.targetChanged(address: address)) }

    public func refreshOutput() { send(.outputChanged(backend.currentOutput())) }

    public func setCurve(_ c: EQCurve) {
        curve = c
        chain.set(curve: c, sampleRate: machine.mounted?.sampleRate ?? 48_000)
    }

    public func setBypass(_ on: Bool) {
        bypass = on
        chain.setBypass(on)
    }

    /// Tom de teste. Só com a tap montada, e ele abre a saída mesmo sem sinal do sistema.
    public func setTone(_ on: Bool) {
        toneOn = on && machine.mounted != nil
        chain.setTone(toneOn)
        chain.setFade(open: toneOn || phase == .active)
    }

    private func send(_ event: ActivationMachine.Event) {
        let commands = machine.handle(event)
        for c in commands {
            switch c {
            case .mount(let d):
                chain.set(curve: curve, sampleRate: d.sampleRate)
                lastFrames = 0
                signalMark = 0
                stuckTicks = 0
            case .unmount:
                toneOn = false
                chain.setTone(false)
                outputLevel = 0
            case .arm, .disarm: break
            }
            backend.perform(c)
        }
        phase = machine.phase
        device = machine.mounted ?? (machine.outputIsTarget ? backend.currentOutput() : nil)
        outputIsTarget = machine.outputIsTarget
        if phase == .active { retriesLeft = Self.maxRetries }
        updateTimer()
        if case .failed = phase, !commands.isEmpty || event == .retry { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard retriesLeft > 0 else { return }
        retriesLeft -= 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.retrySeconds))
            self?.send(.retry)
        }
    }

    private func updateTimer() {
        if machine.mounted == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let t = Timer(timeInterval: Self.tickSeconds, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common) // continua com menu aberto
            timer = t
        }
    }

    func tick() {
        guard let mounted = machine.mounted else { return }
        let s = chain.readStats()
        outputLevel = max(s.outputPeak, outputLevel * 0.85)
        load = s.load
        latency = s.latency

        stuckTicks = s.frames == lastFrames ? stuckTicks + 1 : 0
        lastFrames = s.frames
        if phase == .active, stuckTicks >= Self.stallTicks { return send(.stalled) }

        switch phase {
        case .arming where s.lastSignalFrame > signalMark:
            send(.signalSeen)
        case .active where Double(s.frames &- s.lastSignalFrame) / mounted.sampleRate > Self.silenceSeconds:
            signalMark = s.lastSignalFrame
            send(.silence)
        default: break
        }
    }
}
