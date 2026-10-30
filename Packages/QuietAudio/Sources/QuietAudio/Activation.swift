/// Saída de áudio do sistema, como o Core Audio a descreve.
public struct OutputDevice: Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var sampleRate: Double
    public var channels: Int

    public init(id: UInt32, uid: String, name: String, sampleRate: Double, channels: Int) {
        self.id = id
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// O UID de um dispositivo Bluetooth é `80-99-E7-9D-6C-FF:output`.
    public func matches(bluetoothAddress address: String) -> Bool {
        uid.split(separator: ":").first?.replacing("-", with: ":").uppercased() == address.uppercased()
    }
}

public enum AudioPhase: Equatable, Sendable {
    case off
    /// Ligado, mas a saída atual não é o fone controlado.
    case waitingForOutput
    /// O fone é a saída, mas em modo chamada (mono): sem tap, o áudio segue direto.
    case callMode
    /// Tap montada e sem mudo: o sistema continua tocando sozinho até chegar sinal de verdade.
    case arming
    /// Original mudo, Mac tocando o áudio processado.
    case active
    /// Algo falhou. A tap foi desmontada e o áudio segue sem processamento.
    case failed(String)
}

/// Pedido ao backend. Rodam em ordem, um por vez.
public enum AudioCommand: Equatable, Sendable {
    case mount(OutputDevice)
    case arm
    case disarm
    case unmount
}

/// Regras de ativação, sem Core Audio: quem decide é só o estado e o evento.
/// Invariante de segurança: só existe mudo em `.active`, e `.active` só nasce de `.signalSeen`.
public struct ActivationMachine: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case enabled(Bool)
        case outputChanged(OutputDevice?)
        case targetChanged(address: String?)
        /// Chegou áudio de verdade pela tap.
        case signalSeen
        /// Longo silêncio digital com o original mudo. Pode ser só uma pausa, ou a tap ter parado de entregar.
        case silence
        /// O IOProc parou de avançar.
        case stalled
        case failed(String)
        case retry
    }

    public private(set) var phase = AudioPhase.off
    public private(set) var mounted: OutputDevice?
    private var enabled = false
    private var output: OutputDevice?
    private var address: String?

    public init() {}

    /// O fone controlado é a saída atual, em qualquer modo.
    public var outputIsTarget: Bool {
        guard let output, let address else { return false }
        return output.matches(bluetoothAddress: address)
    }

    public mutating func handle(_ event: Event) -> [AudioCommand] {
        switch event {
        case .enabled(let on): enabled = on
        case .outputChanged(let d):
            // Montar a tap mexe no dispositivo e dispara os listeners: sem mudança real, não há o que fazer.
            guard d != output else { return [] }
            output = d
        case .targetChanged(let a): address = a
        case .signalSeen:
            guard phase == .arming else { return [] }
            phase = .active
            return [.arm]
        case .silence:
            guard phase == .active else { return [] }
            phase = .arming
            return [.disarm]
        case .stalled:
            return fail("O áudio do Mac parou de chegar ao processamento.")
        case .failed(let message):
            return fail(message)
        case .retry:
            guard case .failed = phase else { return [] }
            phase = .waitingForOutput
        }
        return evaluate()
    }

    private mutating func fail(_ message: String) -> [AudioCommand] {
        guard mounted != nil || phase != .off else { return [] }
        phase = .failed(message)
        return unmount()
    }

    private mutating func unmount() -> [AudioCommand] {
        guard mounted != nil else { return [] }
        mounted = nil
        return [.unmount]
    }

    /// Compara o que deveria estar montado com o que está. Depois de uma falha, só `.retry` ou uma
    /// mudança real tentam de novo.
    private mutating func evaluate() -> [AudioCommand] {
        let wanted = enabled && outputIsTarget && (output?.channels ?? 0) >= 2 ? output : nil
        if wanted == mounted, wanted != nil { return [] }
        var commands = unmount()
        if let wanted {
            mounted = wanted
            phase = .arming
            commands.append(.mount(wanted))
        } else if !enabled {
            phase = .off
        } else if outputIsTarget {
            phase = .callMode
        } else {
            phase = .waitingForOutput
        }
        return commands
    }
}
