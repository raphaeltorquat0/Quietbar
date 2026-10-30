import MDRKit

/// Fone simulado: confirma frames, responde GETs a partir de `current` e ecoa SETs como NOTIFY.
actor FakeHeadphones: MDRChannel {
    var current: [MDRCommand: MDRMessage]
    var t2Supported = false
    /// Quantos frames de dados ignorar sem ACK (simula ACK perdido).
    var dropAcks = 0
    /// Não responde a estes GETs (simula firmware que não anuncia algo).
    var silent: Set<MDRCommand> = []
    var ackDelay: Duration = .zero
    var neverAck = false
    /// Quantas aberturas falham por timeout, como o pedido que o IOBluetooth perde ao iniciar.
    var openTimeouts = 0
    /// Erro definitivo ao abrir: fone sem o serviço, por exemplo.
    var openError: (any Error)?
    private(set) var openCalls = 0
    /// `false` = confirma SETs mas não ecoa NOTIFY.
    var echoSets = true

    private(set) var received: [MDRFrame] = []
    private(set) var acksFromHost: [UInt8] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    private var parser = MDRFrameParser()
    private var out: AsyncStream<[UInt8]>.Continuation?
    private var deviceSeq: UInt8 = 0

    init(current: [MDRCommand: MDRMessage] = FakeHeadphones.xm5) { self.current = current }

    static let xm5: [MDRCommand: MDRMessage] = [
        .protocolInfo: .protocolInfo(version: 0x0300_3018, table1: true, table2: false),
        .capabilityInfo: .capabilityInfo(counter: 1, uniqueID: "AC:80:0A:00:00:01"),
        .firmwareVersion: .firmwareVersion("2.5.1"),
        .modelName: .modelName("WH-1000XM5"),
        .seriesAndColor: .seriesAndColor(series: 0x30, color: 0x01),
        .supportFunctions(.t1): .supportFunctions([0x12, 0x20, 0x6B, 0x50, 0xE2, 0xFC, 0xD2, 0x90].map { SupportFunction($0) }),
        .codec: .codec(.ldac),
        .battery(0x00): .battery(BatteryStatus(level: 70)),
        .noiseControl(0x17): .noiseControl(NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: false, ambientLevel: 20)),
        .equalizerAvailable: .equalizerAvailable(true),
        .equalizer: .equalizer(EqualizerParam(presetID: 0x10, steps: [10, 10, 10, 10, 10, 10])),
        .equalizerPresets(0x00): .equalizerPresets(inquiredType: 0, bands: 6, steps: 21, [EqPreset(id: 0x10, name: "Bright")]),
        .dseeAvailable: .dseeAvailable(true),
        .dsee: .dsee(false),
        .dseeType: .dseeType(0x03),
        .speakToChat: .speakToChat(false),
        .speakToChatConfig: .speakToChatConfig(SpeakToChatConfig(sensitivity: 0, modeOutTime: 1)),
        .generalSettingCapability(0xD2): .generalSettingCapability(GeneralSettingCapability(
            inquiredType: 0xD2, subject: "MULTIPOINT_SETTING", summary: "MULTIPOINT_SETTING_SUMMARY")),
        .generalSetting(0xD2): .generalSetting(inquiredType: 0xD2, on: true),
    ]

    /// Earbuds sem cancelamento de ruído e com EQ de 10 bandas, como o LinkBuds Clip (WF-LC900).
    static let linkBudsClip: [MDRCommand: MDRMessage] = [
        .protocolInfo: .protocolInfo(version: 0x0300_3015, table1: true, table2: false),
        .capabilityInfo: .capabilityInfo(counter: 1, uniqueID: "AC:80:0A:00:00:02"),
        .firmwareVersion: .firmwareVersion("2.0.3"),
        .modelName: .modelName("LinkBuds Clip"),
        .seriesAndColor: .seriesAndColor(series: 0x60, color: 0x01),
        .supportFunctions(.t1): .supportFunctions([0x29, 0x2A, 0x50].map { SupportFunction($0) }),
        .battery(0x09): .batteryLR(EarbudsBattery(left: BatteryStatus(level: 78, threshold: 100),
                                                  right: BatteryStatus(level: 0, threshold: 100))),
        .battery(0x0A): .batteryCase(BatteryStatus(level: 60, threshold: 31)),
        .equalizerAvailable: .equalizerAvailable(true),
        .equalizer: .equalizer(EqualizerParam(presetID: 0x00, steps: Array(repeating: 6, count: 10))),
        .equalizerPresets(0x00): .equalizerPresets(inquiredType: 0, bands: 10, steps: 13, [EqPreset(id: 0x30, name: "")]),
    ]

    func configure(_ f: @Sendable (isolated FakeHeadphones) -> Void) { f(self) }

    // MARK: MDRChannel

    func open() async throws -> AsyncStream<[UInt8]> {
        openCalls += 1
        if let openError { throw openError }
        if openTimeouts > 0 {
            openTimeouts -= 1
            throw MDRChannelOpenTimeout()
        }
        let (s, c) = AsyncStream.makeStream(of: [UInt8].self)
        out = c
        parser = MDRFrameParser()
        return s
    }

    func write(_ bytes: [UInt8]) async throws {
        for case .success(let f) in parser.push(bytes) { await handle(f) }
    }

    func close() async {
        out?.finish()
        out = nil
    }

    // MARK: Simulação

    /// O fone fecha o canal (desligou, saiu de alcance…).
    func dropConnection() { out?.finish(); out = nil }

    /// Notificação espontânea (botão físico).
    func notify(_ m: MDRMessage) {
        if let r = m.refresh { current[r] = m }
        emit(m.command(.notify))
    }

    private func handle(_ f: MDRFrame) async {
        if f.type == .ack { acksFromHost.append(f.seq); return }
        received.append(f)
        if dropAcks > 0 { dropAcks -= 1; return }
        if neverAck { return }
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if ackDelay > .zero { try? await Task.sleep(for: ackDelay) }
        inFlight -= 1
        out?.yield(MDRFrame.ack(for: f.seq).encoded())

        let cmd = MDRCommand(f.payload, table: f.type == .mdrNo2 ? .t2 : .t1)
        if let (verb, m) = MDRMessage.decode(f.payload, table: cmd.table), verb == .set {
            if case .alertsEnabled = m { return }
            if echoSets { notify(m) }
        } else if !silent.contains(cmd), let m = current[cmd] {
            emit(m.command(.ret), table: cmd.table)
        }
    }

    private func emit(_ c: MDRCommand, table: MDRTable = .t1) {
        out?.yield(MDRFrame(type: table.dataType, seq: deviceSeq, payload: c.payload).encoded())
        deviceSeq = 1 &- deviceSeq
    }
}
