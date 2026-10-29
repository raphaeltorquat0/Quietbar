import Testing
@testable import MDRKit

/// Trava o comportamento do WH-1000XM5 de antes do suporte a outros fones (commit 4b05bc7).
/// A lista dourada foi gerada rodando o código antigo; se mudar, o XM5 passou a conversar diferente.
@Suite struct XM5RegressionTests {
    static let golden = "D0D101 D6D1 D0D201 D6D2 E001 1202 2200 A620 A201 6617 F60C FA0C 500001 5200 5600 E600 E201 E601 6630 2005 2605 F601"

    private func hex(_ c: MDRCommand) -> String { c.payload.map { String(format: "%02X", $0) }.joined() }

    @Test func syncCommandsUnchanged() {
        let c = MDRCapabilities.wh1000xm5
        #expect(c.syncCommands.map(hex).joined(separator: " ") == Self.golden)
        #expect(c.batteryType == 0x00 && c.noiseControlType == 0x17 && c.equalizerType == 0x00 && c.autoPowerOffType == 0x05)
        // Nada de earbuds para o XM5.
        #expect(!c.isEarbuds && c.leftRightBatteryType == nil && c.caseBatteryType == nil)
    }

    /// O mesmo vale para as capacidades que o fone real anunciou (frames gravados do XM5).
    @Test func syncCommandsFromRealAnnouncementUnchanged() throws {
        var s = MDRDeviceState()
        for (hexFrame, table) in [(XM5.supportT1, MDRTable.t1), (XM5.supportT2, .t2)] {
            let f = try MDRFrame(decoding: [UInt8](hex: hexFrame))
            guard case .supportFunctions(let fs) = try #require(MDRMessage.decode(f.payload, table: table)).1 else { Issue.record(); return }
            s.apply(.supportFunctions(fs), table: table)
        }
        #expect(s.capabilities.syncCommands.map(hex).joined(separator: " ") == Self.golden)
    }

    /// O construtor novo de N bandas gera exatamente os bytes do construtor antigo de 5 bandas.
    @Test(arguments: [[0, 0, 0, 0, 0, 0], [9, 0, 0, 2, 4, 6], [-10, 10, -10, 10, -10, 10], [10, -3, 5, 0, -7, 2]])
    func equalizerBytesUnchanged(_ curve: [Int]) {
        let old = EqualizerParam(presetID: 0xA2, clearBass: curve[0], bands: Array(curve.dropFirst()))
        let new = EqualizerParam(presetID: 0xA2, values: curve)
        #expect(old.steps == new.steps)
        #expect(new.steps == curve.map { UInt8($0 + 10) }) // passo = dB + 10, como antes
        #expect(MDRMessage.equalizer(new).command(.set).payload == [0x58, 0x00, 0xA2, 0x06] + new.steps)
        #expect(new.values == curve && new.clearBass == curve[0] && new.bands == Array(curve.dropFirst()))
    }

    /// Estado do XM5 real lido dos frames gravados: bateria única, sem L/R nem estojo.
    @Test func batteryStaysSingle() throws {
        let f = try MDRFrame(decoding: [UInt8](hex: XM5.battery))
        let m = try #require(MDRMessage.decode(f.payload, table: .t1)).1
        var s = MDRDeviceState()
        s.apply(m)
        #expect(s.battery?.level == 55 && s.batteryLR == nil && s.batteryCase == nil)
        #expect(s.primaryBattery == s.battery)
    }
}
