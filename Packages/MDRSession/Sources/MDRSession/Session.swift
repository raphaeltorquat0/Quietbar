import Foundation
import MDRKit

public enum MDRSessionError: Error, Equatable, Sendable, LocalizedError {
    case notConnected
    case noAck(MDRCommand)
    case timeout(String)
    case unsupportedProtocol
    case readOnly(MDRCommand)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Fone não conectado"
        case .noAck(let c): "O fone não confirmou o comando \(c)"
        case .timeout(let what): "Sem resposta do fone (\(what))"
        case .unsupportedProtocol: "O fone não fala MDR v2 Tabela 1"
        case .readOnly(let c): "Comando recusado no modo somente leitura: \(c)"
        }
    }
}

/// Dono único do canal com o fone. Serializa comandos (um por vez, com ACK e retry),
/// confirma o que chega e mantém o estado — que só muda pelo que o fone responde ou notifica.
public actor MDRSession {
    public enum Phase: Sendable, Equatable {
        case disconnected, connecting, ready
        case failed(String)
    }

    public struct Snapshot: Sendable, Equatable {
        public var phase: Phase
        public var state: MDRDeviceState
        public init(phase: Phase, state: MDRDeviceState) {
            self.phase = phase
            self.state = state
        }
    }

    public enum Direction: Sendable { case tx, rx }

    public struct Options: Sendable {
        public var ackTimeout: Duration = .seconds(1)
        public var attempts = 3
        public var backoff: Duration = .milliseconds(150)
        public var responseTimeout: Duration = .seconds(3)
        /// Só GET sai para o fone: o handshake pula a inscrição em alertas, que é um SET.
        public var readOnly = false
        /// Tentativas de abrir o canal. Logo depois de iniciar o processo, o IOBluetooth pode perder o
        /// pedido sem avisar: o fone nem chega a recebê-lo (DECISIONS.md #88).
        public var openAttempts = 3
        public var openRetryDelay: Duration = .milliseconds(300)
        public init() {}
    }

    private let channel: MDRChannel
    private let options: Options
    private let traffic: (@Sendable (Direction, [UInt8]) -> Void)?

    public private(set) var phase: Phase = .disconnected
    public private(set) var state = MDRDeviceState()

    private var seq: UInt8 = 0
    private var parser = MDRFrameParser()
    private var reader: Task<Void, Never>?
    private var generation = 0

    private var ackWaiter: AckWaiter?
    private var messageWaiters: [Int: Waiter] = [:]
    private var nextID = 0
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var observers: [Int: AsyncStream<Snapshot>.Continuation] = [:]

    /// `traffic` recebe cada frame cru (para `--log-hex` e captura de bugs).
    public init(channel: MDRChannel, options: Options = Options(),
                traffic: (@Sendable (Direction, [UInt8]) -> Void)? = nil) {
        self.channel = channel
        self.options = options
        self.traffic = traffic
    }

    public var snapshot: Snapshot { Snapshot(phase: phase, state: state) }

    /// Stream de snapshots; emite o atual na hora e depois cada mudança.
    public func snapshots() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: Snapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = takeID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    // MARK: - Ciclo de vida

    public func connect() async throws {
        guard phase != .ready, phase != .connecting else { return }
        setPhase(.connecting)
        generation += 1
        let gen = generation
        do {
            let incoming = try await openChannel()
            seq = 0
            parser = MDRFrameParser()
            state = MDRDeviceState()
            reader = Task { [weak self] in
                for await chunk in incoming { await self?.receive(chunk) }
                await self?.channelClosed(generation: gen)
            }
            try await handshake()
            setPhase(.ready)
        } catch {
            generation += 1 // o fechamento do canal não deve trocar `.failed` por `.disconnected`
            await teardown()
            setPhase(.failed(error.localizedDescription))
            throw error
        }
    }

    private func openChannel() async throws -> AsyncStream<[UInt8]> {
        for _ in 1..<max(1, options.openAttempts) {
            do {
                return try await channel.open()
            } catch is MDRChannelOpenTimeout {
                try? await Task.sleep(for: options.openRetryDelay)
            }
        }
        return try await channel.open()
    }

    public func disconnect() async {
        generation += 1
        await teardown()
        setPhase(.disconnected)
    }

    private func teardown() async {
        reader?.cancel()
        reader = nil
        await channel.close()
        failWaiters()
    }

    private func channelClosed(generation gen: Int) {
        guard gen == generation else { return }
        reader = nil
        failWaiters()
        if phase != .disconnected { setPhase(.disconnected) }
    }

    /// Sequência de `RequestInitV2` de [M] (docs/PROTOCOL.md §4).
    private func handshake() async throws {
        let info = try await request(.protocolInfo, "protocol info") {
            if case .protocolInfo = $0 { true } else { false }
        }
        guard case let .protocolInfo(_, table1, _) = info, table1 else { throw MDRSessionError.unsupportedProtocol }

        for c in [MDRCommand.capabilityInfo, .firmwareVersion, .modelName, .seriesAndColor] { try await send(c) }

        do {
            _ = try await request(.supportFunctions(.t1), "funções T1") { if case .supportFunctions = $0 { true } else { false } }
            if state.hasTable2 {
                _ = try await request(.supportFunctions(.t2), "funções T2") { if case .supportFunctions = $0 { true } else { false } }
            }
        } catch MDRSessionError.timeout {
            // Sem a lista de funções. Uma T1 que já chegou fica (o timeout pode ter sido só na T2).
            // O perfil de fallback é a lista real do WH-1000XM5: só vale para ele (ou modelo ainda
            // desconhecido); outro modelo fica só com o que anunciou.
            let isXM5 = state.modelName.map { $0.hasPrefix("WH-1000XM5") } ?? true
            if state.capabilities.table1.isEmpty, isXM5 {
                state.capabilities = .wh1000xm5
                publish()
            }
        }

        if state.capabilities.alerts, !options.readOnly { try await send(MDRMessage.alertsEnabled(true).command(.set)) }
        try await sync()
    }

    /// Relê todo o estado suportado.
    public func sync() async throws {
        for c in state.capabilities.syncCommands { try await send(c) }
    }

    // MARK: - Envio

    /// Envia um comando e espera o ACK (retry com backoff). Não espera a resposta.
    public func send(_ command: MDRCommand) async throws {
        guard reader != nil else { throw MDRSessionError.notConnected }
        guard !options.readOnly || command.isRead else { throw MDRSessionError.readOnly(command) }
        await acquire()
        defer { release() }
        let frame = MDRFrame(type: command.table.dataType, seq: seq, payload: command.payload).encoded()
        for attempt in 0..<options.attempts {
            if attempt > 0 { try? await Task.sleep(for: options.backoff * (1 << (attempt - 1))) }
            guard reader != nil else { throw MDRSessionError.notConnected }
            let id = takeID()
            ackWaiter = AckWaiter(id: id, expected: 1 &- seq) // antes de escrever: o ACK pode chegar já
            try await write(frame)
            if await waitAck(id) {
                seq = 1 &- seq
                return
            }
        }
        throw MDRSessionError.noAck(command)
    }

    /// Envia e espera a primeira mensagem que satisfaça `match`.
    /// O waiter é registrado antes do envio: a resposta pode chegar logo depois do ACK.
    @discardableResult
    public func request(_ command: MDRCommand, _ what: String = "resposta",
                        match: @escaping @Sendable (MDRMessage) -> Bool) async throws -> MDRMessage {
        let id = takeID()
        messageWaiters[id] = Waiter(match: match)
        do {
            try await send(command)
        } catch {
            messageWaiters[id] = nil
            throw error
        }
        let timeout = Task { [options] in
            try? await Task.sleep(for: options.responseTimeout)
            self.resolveWaiter(id, nil)
        }
        defer { timeout.cancel() }
        let answer: MDRMessage? = await withCheckedContinuation { c in
            if let w = messageWaiters[id], w.done {
                messageWaiters[id] = nil
                c.resume(returning: w.result)
            } else {
                messageWaiters[id]?.continuation = c
            }
        }
        guard let answer else { throw MDRSessionError.timeout(what) }
        return answer
    }

    /// SET + releitura do mesmo valor: a UI só muda quando o fone confirma o novo estado.
    public func set(_ message: MDRMessage) async throws {
        try await send(message.command(.set))
        if let r = message.refresh { try await send(r) }
    }

    private func write(_ bytes: [UInt8]) async throws {
        traffic?(.tx, bytes)
        try await channel.write(bytes)
    }

    private func waitAck(_ id: Int) async -> Bool {
        let timeout = Task { [options] in
            try? await Task.sleep(for: options.ackTimeout)
            self.resolveAck(id, false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { c in
            guard let w = ackWaiter, w.id == id else { return c.resume(returning: false) }
            if w.arrived {
                ackWaiter = nil
                c.resume(returning: true)
            } else {
                ackWaiter?.continuation = c
            }
        }
    }

    // MARK: - Recepção

    private func receive(_ chunk: [UInt8]) async {
        for result in parser.push(chunk) {
            guard case .success(let frame) = result else {
                if case .failure = result { traffic?(.rx, chunk) }
                continue
            }
            traffic?(.rx, frame.encoded())
            switch frame.type {
            case .ack:
                if let w = ackWaiter, frame.seq == w.expected { resolveAck(w.id, true) }
            case .mdr, .mdrNo2:
                try? await write(MDRFrame.ack(for: frame.seq).encoded())
                let table: MDRTable = frame.type == .mdr ? .t1 : .t2
                guard let (_, message) = MDRMessage.decode(frame.payload, table: table) else { continue }
                state.apply(message, table: table)
                publish()
                for (id, w) in messageWaiters where !w.done && w.match(message) { resolveWaiter(id, message) }
            default:
                continue
            }
        }
    }

    // MARK: - Utilidades internas

    func takePendingAlert() -> MDRAlert? {
        defer { state.pendingAlert = nil; publish() }
        return state.pendingAlert
    }

    private func takeID() -> Int { nextID += 1; return nextID }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    private struct AckWaiter {
        var id: Int
        var expected: UInt8
        var arrived = false
        var continuation: CheckedContinuation<Bool, Never>?
    }

    private func resolveAck(_ id: Int, _ value: Bool) {
        guard var w = ackWaiter, w.id == id, !w.arrived else { return }
        if let c = w.continuation {
            ackWaiter = nil
            c.resume(returning: value)
        } else if value {
            w.arrived = true
            ackWaiter = w
        } else {
            ackWaiter = nil
        }
    }

    private struct Waiter {
        var match: @Sendable (MDRMessage) -> Bool
        var continuation: CheckedContinuation<MDRMessage?, Never>?
        var done = false
        var result: MDRMessage?
    }

    private func resolveWaiter(_ id: Int, _ value: MDRMessage?) {
        guard var w = messageWaiters[id], !w.done else { return }
        if let c = w.continuation {
            messageWaiters[id] = nil
            c.resume(returning: value)
        } else {
            w.done = true
            w.result = value
            messageWaiters[id] = w
        }
    }

    private func failWaiters() {
        if let w = ackWaiter { resolveAck(w.id, false) }
        for id in messageWaiters.keys { resolveWaiter(id, nil) }
    }

    private func removeObserver(_ id: Int) { observers[id] = nil }

    private func setPhase(_ p: Phase) {
        phase = p
        publish()
    }

    private func publish() {
        let s = snapshot
        for o in observers.values { o.yield(s) }
    }
}
