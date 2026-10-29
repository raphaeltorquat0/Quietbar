import Testing
@testable import MDRKit

// Frames reais (RX) das capturas públicas do SonyHeadphonesClient [M] (`tests/`, MIT),
// já sem dados pessoais. Cobrem o que o WH-1000XM5 não tem: bateria esquerda/direita + estojo,
// fone sem cancelamento de ruído e EQ de 10 bandas.

/// WF-1000XM5 fw 6.1.0 (`tests/WF-1000XM5-6.1.0/`).
enum WFXM5 {
    static let model = "3e0c000000000d05010a57462d31303030584d358e3c"
    static let supportT1 = "3e0c000000005f07002e10ff12ff13ff14ff15ff16ff17ff23ff253611ff27ff29ff2aff92ff50116b08700190ffa112c1ffc2ffe21bf138fc0d93fff633f941d13b94ff402e423a44ffff2d19fff326e71ad220fd2bb61db042b243b81fb715343ff423f524293c"
    static let noiseControl = "3e0c010000000767170100010014a83c"
    static let eq = "3e0c010000000a5700a006140b0a0d090c5f3c"
    static let batteryLR = "3e0c000000000823090000640064646c3c"
    static let batteryCase = "3e0c0100000005230a35001e923c"
}

/// LinkBuds Clip (WF-LC900) fw 2.0.3 (`tests/WF-LC900-2.0.3*/`): sem NC, EQ de 10 bandas.
enum LinkBudsClip {
    static let model = "3e0c010000001005010d4c696e6b4275647320436c6970f43c"
    static let supportT1 = "3e0c010000003f07001e10ff11ff12ff13ff14ff15ff17ff19ff23ff27ff29ff2aff3214500490ffa105b215b808c1ffd209d30ee106e207eb10e602e8ffe9fff30cfa0afd0d023c"
    static let eqPresets = "3e0c000000001551000a0d0800003000310032003300a000a100a2003a3c"
    static let eqFlat = "3e0c010000000e5700000a06060606060606060606b83c"
    static let eqHeavy = "3e0c010000000e5700300a0a0a0505060606060606ee3c"
    static let batteryLR = "3e0c010000000823094e0000006464573c"
    /// Nível 0x3C vem escapado (`3d 2c`) no fio.
    static let batteryCase = "3e0c0100000005230a3d2c001f9a3c"
}

private func message(_ hex: String) throws -> MDRMessage {
    let f = try MDRFrame(decoding: [UInt8](hex: hex))
    #expect(f.encoded() == [UInt8](hex: hex))
    let (verb, m) = try #require(MDRMessage.decode(f.payload, table: f.type == .mdrNo2 ? .t2 : .t1))
    // Re-encode da mensagem decodificada (com o mesmo verbo) reproduz o payload original.
    #expect(m.command(verb).payload == f.payload)
    return m
}

private func capabilities(_ hex: String) throws -> MDRCapabilities {
    guard case .supportFunctions(let fs) = try message(hex) else { Issue.record("sem funções"); return MDRCapabilities() }
    var s = MDRDeviceState()
    s.apply(.supportFunctions(fs))
    return s.capabilities
}

@Suite struct WF1000XM5Tests {
    @Test func identityAndCapabilities() throws {
        #expect(try message(WFXM5.model) == .modelName("WF-1000XM5"))
        let c = try capabilities(WFXM5.supportT1)
        #expect(c.isEarbuds)
        #expect(c.batteryType == nil)
        #expect(c.leftRightBatteryType == 0x09)
        #expect(c.caseBatteryType == 0x0A)
        #expect(c.noiseControlType == 0x17)
        #expect(c.syncCommands.contains(.battery(0x09)) && c.syncCommands.contains(.battery(0x0A)))
    }

    @Test func batteryLeftRightAndCase() throws {
        guard case .batteryLR(let lr) = try message(WFXM5.batteryLR) else { Issue.record(); return }
        #expect(lr.left.level == 0 && lr.right.level == 100)
        #expect(lr.present.map(\.level) == [100]) // lado esquerdo fora do ouvido/estojo
        #expect(lr.left.threshold == 100 && lr.right.threshold == 100)
        #expect(try message(WFXM5.batteryCase) == .batteryCase(BatteryStatus(level: 0x35, threshold: 0x1E)))

        var s = MDRDeviceState()
        s.apply(.batteryLR(lr))
        #expect(s.primaryBattery?.level == 100)
    }

    @Test func noiseControlAndSixBandEqualizer() throws {
        guard case .noiseControl(let n) = try message(WFXM5.noiseControl) else { Issue.record(); return }
        #expect(n.inquiredType == 0x17 && n.ambientLevel == 20)
        guard case .equalizer(let eq) = try message(WFXM5.eq) else { Issue.record(); return }
        #expect(eq.presetID == 0xA0 && eq.isFiveBand)
        #expect(eq.values == [10, 1, 0, 3, -1, 2])
        #expect(eq.labels.first == "Clear Bass")
    }
}

@Suite struct LinkBudsClipTests {
    @Test func noNoiseCancellingAndTenBandEqualizer() throws {
        #expect(try message(LinkBudsClip.model) == .modelName("LinkBuds Clip"))
        let c = try capabilities(LinkBudsClip.supportT1)
        #expect(c.isEarbuds)
        #expect(c.noiseControlType == nil)
        #expect(c.equalizerType == 0x00)
    }

    @Test func presetsWithoutNames() throws {
        guard case let .equalizerPresets(_, bands, steps, presets) = try message(LinkBudsClip.eqPresets) else { Issue.record(); return }
        #expect(bands == 10 && steps == 13)
        #expect(presets.map(\.id) == [0x00, 0x30, 0x31, 0x32, 0x33, 0xA0, 0xA1, 0xA2])
        #expect(presets.allSatisfy { $0.name.isEmpty })
    }

    @Test func tenBandEqualizer() throws {
        guard case .equalizer(let flat) = try message(LinkBudsClip.eqFlat),
              case .equalizer(let heavy) = try message(LinkBudsClip.eqHeavy) else { Issue.record(); return }
        #expect(flat.values == Array(repeating: 0, count: 10))
        #expect(flat.labels == EqualizerParam.tenBandLabels)
        #expect(heavy.presetID == 0x30)
        #expect(heavy.values == [4, 4, -1, -1, 0, 0, 0, 0, 0, 0])
        #expect(heavy.range == -6...6)
        // Escrever uma curva de 10 bandas gera os mesmos passos que o fone usa.
        #expect(EqualizerParam(presetID: 0x30, values: heavy.values).steps == heavy.steps)
    }

    @Test func batteryWithEscapedCaseLevel() throws {
        guard case .batteryLR(let lr) = try message(LinkBudsClip.batteryLR) else { Issue.record(); return }
        #expect(lr.left.level == 78 && lr.right.level == 0)
        #expect(try message(LinkBudsClip.batteryCase) == .batteryCase(BatteryStatus(level: 0x3C, threshold: 0x1F)))
    }
}
