import MDRKit

public enum VirtualTransportError: Error {
    case unreachable
}

/// O mesmo `MDRChannel` do RFCOMM, ligado a um `VirtualDevice`. A sessão não sabe a diferença.
public actor VirtualTransport: MDRChannel {
    public private(set) var device: VirtualDevice
    /// Atraso antes de cada resposta do fone.
    public var latency: Duration = .zero
    /// O fone recebe, mas não confirma nem responde.
    public var unresponsive = false
    /// `false`: o canal não abre, como um fone desligado ou fora de alcance.
    public var reachable = true

    private var parser = MDRFrameParser()
    private var output: AsyncStream<[UInt8]>.Continuation?

    public init(profile: DeviceProfile) { device = VirtualDevice(profile: profile) }

    public var isOpen: Bool { output != nil }

    public func configure(_ change: @Sendable (isolated VirtualTransport) -> Void) { change(self) }

    // MARK: MDRChannel

    public func open() async throws -> AsyncStream<[UInt8]> {
        guard reachable else { throw VirtualTransportError.unreachable }
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        output = continuation
        parser = MDRFrameParser()
        return stream
    }

    public func write(_ bytes: [UInt8]) async throws {
        for case .success(let frame) in parser.push(bytes) where !unresponsive {
            // Como no RFCOMM, escrever não espera o fone: quem atrasa é a resposta.
            guard latency > .zero else { reply(to: frame); continue }
            let delay = latency
            Task {
                try? await Task.sleep(for: delay)
                self.reply(to: frame)
            }
        }
    }

    private func reply(to frame: MDRFrame) {
        for r in device.receive(frame) { send(r) }
    }

    public func close() async {
        output?.finish()
        output = nil
    }

    // MARK: Eventos do fone

    /// Mudança espontânea, como um botão físico ou a bateria descendo.
    public func event(_ message: MDRMessage) {
        send(device.event(message))
    }

    /// O fone some: desligou ou saiu de alcance.
    public func dropConnection() {
        output?.finish()
        output = nil
    }

    /// Bytes crus do fone, como um frame corrompido.
    public func emit(raw bytes: [UInt8]) {
        output?.yield(bytes)
    }

    private func send(_ frame: MDRFrame) {
        output?.yield(frame.encoded())
    }
}
