import Testing
import MDRKit
@testable import MDRSession

private func fastOptions() -> MDRSession.Options {
    var o = MDRSession.Options()
    o.ackTimeout = .milliseconds(60)
    o.backoff = .milliseconds(10)
    o.responseTimeout = .milliseconds(250)
    return o
}

/// Espera o estado satisfazer `cond` (as RETs chegam depois dos ACKs).
private func eventually(_ s: MDRSession, _ cond: @Sendable (MDRDeviceState) -> Bool) async -> Bool {
    for _ in 0..<100 {
        if cond(await s.state) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Suite struct SessionTests {
    @Test func handshakeReadsIdentityAndCapabilities() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        #expect(await s.phase == .ready)
        #expect(await eventually(s) { $0.modelName == "WH-1000XM5" && $0.firmwareVersion == "2.5.1" })
        let st = await s.state
        #expect(!st.capabilities.isFallback)
        #expect(st.capabilities.noiseControlType == 0x17)
        #expect(await eventually(s) { $0.noiseControl?.soundMode == .noiseCanceling && $0.codec == .ldac })
        #expect(await eventually(s) { $0.generalSetting(subject: "MULTIPOINT_SETTING")?.on == true })
        #expect(await eventually(s) { $0.equalizerPresets.map(\.name) == ["Bright"] })
        // Alertas habilitados porque o fone anuncia FIXED_MESSAGE (0x90).
        #expect(await fake.received.contains { $0.payload == [0x94, 0x00, 0x00] })
    }

    @Test func sequenceAlternatesAndDeviceFramesAreAcked() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        let seqs = await fake.received.map(\.seq)
        #expect(seqs.prefix(4) == [0, 1, 0, 1])
        let acks = await fake.acksFromHost
        #expect(!acks.isEmpty)
        #expect(acks.prefix(2) == [1, 0]) // ACK leva 1 - seq do frame do fone
    }

    @Test func notifyFromPhysicalButtonUpdatesState() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        let snaps = await s.snapshots()
        try await s.connect()
        #expect(await eventually(s) { $0.noiseControl != nil })
        await fake.notify(.noiseControl(NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: true, ambientLevel: 12)))
        var sawAmbient = false
        for await snap in snaps where snap.state.noiseControl?.soundMode == .ambient {
            #expect(snap.state.noiseControl?.ambientLevel == 12)
            sawAmbient = true
            break
        }
        #expect(sawAmbient)
    }

    @Test func setChangesStateOnlyThroughDeviceAnswer() async throws {
        // Fone que confirma o SET mas não ecoa nem responde à releitura: nada muda na sessão.
        let mute = FakeHeadphones()
        let s1 = MDRSession(channel: mute, options: fastOptions())
        try await s1.connect()
        #expect(await eventually(s1) { $0.noiseControl?.soundMode == .noiseCanceling })
        await mute.configure { $0.echoSets = false; $0.silent = [.noiseControl(0x17)] }
        try await s1.setSoundMode(.ambient)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await s1.state.noiseControl?.soundMode == .noiseCanceling)

        // Fone normal: o NOTIFY de volta é o que muda o estado.
        let fake = FakeHeadphones()
        let s2 = MDRSession(channel: fake, options: fastOptions())
        try await s2.connect()
        try await s2.setSoundMode(.ambient)
        #expect(await eventually(s2) { $0.noiseControl?.soundMode == .ambient })
        let sent = await fake.received.last { $0.payload.first == 0x68 }
        #expect(sent?.payload == [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x14])
        #expect(await fake.received.last?.payload == [0x66, 0x17]) // releitura depois do SET
    }

    @Test func retriesAfterLostAck() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        let before = await fake.received.count
        await fake.configure { $0.dropAcks = 2 }
        try await s.send(.codec)
        let frames = await fake.received.dropFirst(before)
        #expect(frames.count == 3)
        #expect(Set(frames.map(\.seq)).count == 1) // retransmite com o mesmo seq
    }

    @Test func failsAfterThreeAttempts() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        await fake.configure { $0.neverAck = true }
        await #expect(throws: MDRSessionError.noAck(.codec)) { try await s.send(.codec) }
    }

    @Test func fallsBackToXM5ProfileWhenSupportFunctionsTimeout() async throws {
        let fake = FakeHeadphones()
        await fake.configure { $0.silent = [.supportFunctions(.t1)] }
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        #expect(await s.state.capabilities == .wh1000xm5)
    }

    @Test func earbudsWithoutNoiseCancelling() async throws {
        let fake = FakeHeadphones(current: FakeHeadphones.linkBudsClip)
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        #expect(await eventually(s) { $0.batteryLR != nil && $0.batteryCase != nil && $0.equalizer != nil })
        let st = await s.state
        #expect(st.capabilities.isEarbuds && st.noiseControl == nil)
        #expect(st.primaryBattery?.level == 78) // só o lado presente conta
        #expect(st.equalizer?.values.count == 10)
        // EQ de 10 bandas passa pelo setter genérico sem cair no layout de 6.
        try await s.setEqualizer(values: [4, 4, -1, -1, 0, 0, 0, 0, 0, 0])
        #expect(await eventually(s) { $0.equalizer?.values.first == 4 })
    }

    @Test func fallbackProfileIsOnlyForXM5() async throws {
        var other = FakeHeadphones.linkBudsClip
        other[.supportFunctions(.t1)] = nil
        let fake = FakeHeadphones(current: other)
        await fake.configure { $0.silent = [.supportFunctions(.t1)] }
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        // Outro modelo sem lista de funções não herda o perfil do XM5.
        #expect(await s.state.capabilities.table1.isEmpty)
    }

    @Test func handshakeFailsWithoutProtocolInfo() async throws {
        let fake = FakeHeadphones()
        await fake.configure { $0.silent = [.protocolInfo] }
        let s = MDRSession(channel: fake, options: fastOptions())
        await #expect(throws: MDRSessionError.self) { try await s.connect() }
        if case .failed = await s.phase {} else { Issue.record("fase deveria ser failed") }
    }

    @Test func deviceDisconnectEndsSession() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        await fake.dropConnection()
        var disconnected = false
        for _ in 0..<50 where !disconnected {
            disconnected = await s.phase == .disconnected
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(disconnected)
        await #expect(throws: MDRSessionError.notConnected) { try await s.send(.codec) }
        // Reabre sob demanda.
        try await s.connect()
        #expect(await s.phase == .ready)
    }

    @Test func commandsAreSerialized() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        await fake.configure { $0.ackDelay = .milliseconds(15) }
        await withThrowingTaskGroup(of: Void.self) { g in
            for c in [MDRCommand.codec, .dsee, .volume, .speakToChat, .equalizer] { g.addTask { try await s.send(c) } }
        }
        #expect(await fake.maxInFlight == 1)
    }

    /// Reproduz o dump que falhava: o primeiro pedido de abertura se perde e nada chega ao fone.
    @Test func retriesWhenTheOpenRequestIsLost() async throws {
        let fake = FakeHeadphones()
        await fake.configure { $0.openTimeouts = 2 }
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        #expect(await s.phase == .ready)
        #expect(await fake.openCalls == 3)
    }

    @Test func givesUpAfterTheLastOpenAttempt() async throws {
        let fake = FakeHeadphones()
        await fake.configure { $0.openTimeouts = 3 }
        let s = MDRSession(channel: fake, options: fastOptions())
        await #expect(throws: MDRChannelOpenTimeout.self) { try await s.connect() }
        #expect(await fake.openCalls == 3)
        if case .failed = await s.phase {} else { Issue.record("a sessão deveria falhar") }
    }

    @Test func doesNotRetryAPermanentOpenError() async throws {
        struct NoService: Error {}
        let fake = FakeHeadphones()
        await fake.configure { $0.openError = NoService() }
        let s = MDRSession(channel: fake, options: fastOptions())
        await #expect(throws: NoService.self) { try await s.connect() }
        #expect(await fake.openCalls == 1)
    }

    /// `dump` e `get` rodam contra o fone real: nada além de GET pode sair.
    @Test func readOnlySendsOnlyGets() async throws {
        let fake = FakeHeadphones()
        var options = fastOptions()
        options.readOnly = true
        let s = MDRSession(channel: fake, options: options)
        try await s.connect()
        let sent = await fake.received
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { MDRCommand($0.payload).isRead }, "\(sent.map(\.payload))")
        await #expect(throws: MDRSessionError.self) { try await s.setDSEE(true) }
        #expect(await fake.received.count == sent.count)
    }

    @Test func alertResponse() async throws {
        let fake = FakeHeadphones()
        await fake.configure { $0.echoSets = false } // o eco da resposta recriaria o alerta
        let s = MDRSession(channel: fake, options: fastOptions())
        try await s.connect()
        await fake.notify(.alert(messageType: 0x07, action: 0x01))
        #expect(await eventually(s) { $0.pendingAlert == MDRAlert(messageType: 0x07, action: 0x01) })
        try await s.respondToAlert(positive: true)
        #expect(await s.state.pendingAlert == nil)
        #expect(await fake.received.last?.payload == [0x98, 0x00, 0x07, 0x01])
    }
}
