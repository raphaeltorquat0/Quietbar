import MDRKit
import MDRSession
import Testing
@testable import MDRTransport

/// Frames literais de NeoHBz/JBLProtocol4 `notes/protocol.md` (Tune 780NC).
@Suite struct JBLProtocolTests {
    @Test func setFramesMatchTheSpec() {
        #expect(JBL.set(JBL.Tag.anc, [0xFF])?.encoded == hex("00dd02000100050018000100ff"))
        #expect(JBL.set(JBL.Tag.anc, [0x7F])?.encoded == hex("00dd020001000500180001007f"))
        #expect(JBL.set(JBL.Tag.ambientAware, [0xFF])?.encoded == hex("00dd02000100050019000100ff"))
        #expect(JBL.set(JBL.Tag.talkThru, [0xFF])?.encoded == hex("00dd0200010005001a000100ff"))
        #expect(JBL.get([0x0C]).encoded == hex("00dd0100010002000c00"))
    }

    @Test func dangerousTagsNeverEncode() {
        for tag: UInt16 in [0x00FF, 0x0011, 0x0101, 0x02FF, 0x003E, 0x004A, 0x004B, 0x0053, 0x0054, 0x0BA0, 0x0BA5] {
            #expect(JBL.set(tag, [0x01]) == nil)
            #expect(JBL.set([(JBL.Tag.anc, [0xFF]), (tag, [0x01])]) == nil)
        }
    }

    /// CRC-16/ARC: vetor padrão "123456789" → `BB3D`. O app usa a mesma tabela (`0, C0C1, C181, 0140…`).
    @Test func hostNameCRC() {
        #expect(JBL.hostNameCRC("123456789") == 0xBB3D)
        #expect(JBL.hostNameCRC(String(repeating: "a", count: 50)) == JBL.hostNameCRC(String(repeating: "a", count: 80)))
        // SET no canal raw: tag 0x0007, 2 bytes little-endian.
        #expect(JBL.setHostNameCRC("123456789").encoded == hex("00dd02000100" + "0600" + "07000200" + "3dbb"))
    }

    /// `LiveTws4Control.setAncSetting`: AmbientSoundControl (0x49) + o tag do modo ligado.
    @Test func liveTws4ModeFrames() {
        var n = NoiseControl(enabled: true, ambientMode: false, ambientLevel: 10)
        #expect(JBL.setMode(n, liveTws4: true)?.encoded == hex("00dd02000100" + "0a00" + "49000100ff" + "18000100ff"))
        n.soundMode = .ambient
        #expect(JBL.setMode(n, liveTws4: true, aaLevel: 0x0A)?.payload == hex("49000100ff" + "190001008a"))
        n.focusOnVoice = true
        #expect(JBL.setMode(n, liveTws4: true)?.payload == hex("49000100ff" + "1a000100ff"))
        n.soundMode = .off
        #expect(JBL.setMode(n, liveTws4: true)?.payload == hex("490001007f" + "1a000100ff"))
    }

    @Test func modeMapping() {
        func n(_ mode: SoundMode, voice: Bool = false) -> NoiseControl {
            var n = NoiseControl(enabled: true, ambientMode: false, focusOnVoice: voice, ambientLevel: 10)
            n.soundMode = mode
            return n
        }
        #expect(JBL.setMode(n(.noiseCanceling)) == JBL.set(JBL.Tag.anc, [0xFF]))
        #expect(JBL.setMode(n(.ambient)) == JBL.set(JBL.Tag.ambientAware, [0xFF]))
        #expect(JBL.setMode(n(.ambient, voice: true)) == JBL.set(JBL.Tag.talkThru, [0xFF]))
        #expect(JBL.setMode(n(.off)) == JBL.set(JBL.Tag.anc, [0x7F]))
    }

    @Test func notificationDecodes() throws {
        // status 0000 + ANC=ff, Ambient=7f, TalkThru=7f + bateria 0x30 (48%).
        let payload = hex("0000" + "180001" + "00ff" + "190001007f" + "1a0001007f" + "0d00010030")
        let v = try #require(JBL.values(payload))
        let base = NoiseControl(enabled: false, ambientMode: false, ambientLevel: 0)
        #expect(JBL.noiseControl(v, base: base)?.soundMode == .noiseCanceling)
        #expect(JBL.battery(v, JBL.Tag.leftBattery) == BatteryStatus(level: 48))
        #expect(JBL.values(hex("0100")) == nil)
        #expect(JBL.values(hex("0000180005ff")) == nil)
        // AmbientSoundControl desligado vence o tag do modo.
        let off = try #require(JBL.values(hex("0000" + "18000100ff190001007f1a0001007f" + "490001007f")))
        #expect(JBL.noiseControl(off, base: base)?.soundMode == .off)
        // Medido no Live Beam 4 desligado: o ANC segue com o bit 7 e só o 0x49 vai a 7f.
        let measured = try #require(JBL.values(hex("0000" + "18000100871900010007" + "1a00010000" + "490001007f")))
        #expect(JBL.noiseControl(measured, base: base)?.soundMode == .off)
    }

    @Test func reassemblesMultiPacket() {
        var r = JBL.Reassembler()
        #expect(r.push(hex("00dd030002000200" + "0000")) == nil)
        let f = r.push(hex("00dd030002010500" + "0d00010030"))
        #expect(f?.payload == hex("00000d00010030"))
        #expect(f?.count == 1)
    }
}

/// A sessão MDR de verdade conversando com a ponte, sem Bluetooth.
private actor BridgeChannel: MDRChannel {
    var bridge = JBLBridge(modelName: "JBL Live Beam 4")
    var sent: [JBL.Frame] = []
    private var parser = MDRFrameParser()
    private var out: AsyncStream<[UInt8]>.Continuation?

    func open() async throws -> AsyncStream<[UInt8]> {
        let (s, c) = AsyncStream.makeStream(of: [UInt8].self)
        out = c
        return s
    }

    func write(_ bytes: [UInt8]) async throws {
        for case .success(let f) in parser.push(bytes) {
            let o = bridge.receive(f)
            sent += o.jbl
            for m in o.mdr { out?.yield(m.encoded()) }
        }
    }

    func close() async { out?.finish() }

    func fromHeadphones(_ f: JBL.Frame) { for m in bridge.receive(f) { out?.yield(m.encoded()) } }
}

@Suite struct JBLBridgeTests {
    @Test func liveBeam4Batteries() {
        var b = JBLBridge(modelName: "JBL Live Beam 4")
        // ProductID 0x2179 (LE) + L 64% carregando, R 60%, estojo 40%.
        let frames = b.receive(JBL.Frame(command: 0x0001, payload: hex("0000" + "040002007921" + "0d000100c0" + "0e0001003c" + "031f010028")))
        #expect(b.isLiveTws4)
        let messages = frames.compactMap { MDRMessage.decode($0.payload)?.1 }
        #expect(messages.contains(.batteryLR(EarbudsBattery(left: BatteryStatus(level: 64, chargingRaw: 1), right: BatteryStatus(level: 60)))))
        #expect(messages.contains(.batteryCase(BatteryStatus(level: 40))))
    }

    @Test func sessionDrivesTheHeadphones() async throws {
        let channel = BridgeChannel()
        let session = MDRSession(channel: channel)
        try await session.connect()
        await until { await session.state.noiseControl != nil }
        var state = await session.state
        #expect(state.modelName == "JBL Live Beam 4")
        #expect(state.noiseControl?.soundMode == .off)

        await channel.fromHeadphones(JBL.Frame(command: 0x0001, payload: hex("0000" + "1900010" + "0ff" + "180001007f1a0001007f0d000100d5")))
        await until { await session.state.primaryBattery != nil }
        state = await session.state
        #expect(state.noiseControl?.soundMode == .ambient)
        #expect(state.primaryBattery == BatteryStatus(level: 0x55, chargingRaw: 1))

        try await session.setSoundMode(.noiseCanceling)
        #expect(await channel.sent == [JBL.set(JBL.Tag.anc, [0xFF])!])
        // `set` volta no ACK da releitura; o RET vem logo depois.
        await until { await session.state.noiseControl?.soundMode == .noiseCanceling }
        #expect(await session.state.noiseControl?.soundMode == .noiseCanceling)

        // Nível de ambiente não existe no JBL: nada sai para o fone.
        try await session.setAmbientLevel(5)
        #expect(await channel.sent.count == 1)
    }
}

@Suite struct JBLLiveBeam4SessionTests {
    @Test func earbudsAndAmbientSoundControl() async throws {
        let channel = BridgeChannel()
        // O `JBLChannel` só entrega o canal depois do ProductID: o fone já respondeu antes da sessão começar.
        await channel.fromHeadphones(JBL.Frame(command: 0x0001, payload: hex("0000" + "040002007921" + "0d00010050" + "0e0001004e" + "031f010028"
                                                                                + "180001007f190001007f1a0001007f")))
        let session = MDRSession(channel: channel)
        try await session.connect()
        await until { await session.state.batteryLR != nil }
        let state = await session.state
        #expect(state.capabilities.leftRightBatteryType == 0x01)
        #expect(state.capabilities.caseBatteryType == 0x02)
        #expect(state.batteryLR?.right.level == 0x4E)
        #expect(state.batteryCase?.level == 0x28)

        try await session.setSoundMode(.noiseCanceling)
        #expect(await channel.sent == [JBL.set([(JBL.Tag.ambientSoundControl, [0xFF]), (JBL.Tag.anc, [0xFF])])!])
    }

    @Test func ambientLevelStaysInTheApp() async throws {
        // O Live Beam 4 guarda o nível, mas o som não muda: mudar só ele não pode sair para o fone.
        let channel = BridgeChannel()
        await channel.fromHeadphones(JBL.Frame(command: 0x0001, payload: hex("0000" + "040002007921" + "0d00010050" + "0e0001004e"
                                                                                + "18000100071900010087" + "1a00010000" + "49000100ff")))
        let session = MDRSession(channel: channel)
        try await session.connect()
        await until { await session.state.noiseControl?.ambientMode == true }
        let before = await channel.sent
        try await session.setAmbientLevel(20)
        #expect(await channel.sent == before)
    }
}

/// Os RETs chegam depois dos ACKs que liberam a sessão: espera o estado, com teto de 1 s.
private func until(_ condition: () async -> Bool) async {
    for _ in 0..<100 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map {
        let i = s.index(s.startIndex, offsetBy: $0)
        return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
    }
}
