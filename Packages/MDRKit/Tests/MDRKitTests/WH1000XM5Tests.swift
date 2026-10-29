import Testing
@testable import MDRKit

/// Frames reais de um WH-1000XM5 fw 2.5.1, capturados com `mdr-cli dump --log-hex` em 2026-10-29.
/// O frame de capability info (que traz o MAC) ficou de fora.
enum XM5 {
    static let protocolInfo = "3e0c010000000801000300201600004f3c"
    static let model = "3e0c000000000d05010a57482d31303030584d35903c"
    static let firmware = "3e0c0100000008050205322e352e31153c"
    static let supportT1 = "3e0c000000004507002110ff12ff13ff14ff23ff252120ff27ffd1193226500a6b06700190ffa10bc1ffc2ffe10de20ff41493ff691ad212f927b028b22bb62af123fd1bfc09b8ffb7ff19fff03c"
    static let supportT2 = "3e0e010000000f070006412550fff2ff320331fff81e4c3c"
    static let eqPresets = "3e0c000000001d510006150c000010001100120013001400150016001700a000a100a200203c"
    static let eq = "3e0c000000000a5700a206130a0a0c0e10663c"
    static let ncAmbButton = "3e0c0000000003673002a83c"
    static let autoPowerOffOptions = "3e0c010000000521050210115b3c"
    static let battery = "3e0c0000000004230037006a3c"
    static let noiseControl = "3e0c01000000076717010100000ca03c"
    static let touchPanel = "3e0c0000000019d1d1000113544f5543485f50414e454c5f53455454494e4700aa3c"
}

private func message(_ hex: String) throws -> MDRMessage {
    let f = try MDRFrame(decoding: [UInt8](hex: hex))
    #expect(f.encoded() == [UInt8](hex: hex))
    return try #require(MDRMessage.decode(f.payload, table: f.type == .mdrNo2 ? .t2 : .t1)).1
}

@Suite struct WH1000XM5Tests {
    @Test func identity() throws {
        #expect(try message(XM5.protocolInfo) == .protocolInfo(version: 0x0300_2016, table1: true, table2: true))
        #expect(try message(XM5.model) == .modelName("WH-1000XM5"))
        #expect(try message(XM5.firmware) == .firmwareVersion("2.5.1"))
    }

    @Test func announcedCapabilitiesMatchFallbackProfile() throws {
        var s = MDRDeviceState()
        guard case .supportFunctions(let t1) = try message(XM5.supportT1),
              case .supportFunctions(let t2) = try message(XM5.supportT2) else { Issue.record(); return }
        s.apply(.supportFunctions(t1))
        s.apply(.supportFunctions(t2), table: .t2)
        #expect(s.capabilities.table1 == MDRCapabilities.wh1000xm5.table1)
        #expect(s.capabilities.table2 == MDRCapabilities.wh1000xm5.table2)
        #expect(s.capabilities.noiseControlType == 0x17)
        #expect(s.capabilities.batteryType == 0x00)
        #expect(s.capabilities.autoPowerOffType == 0x05)
        #expect(s.capabilities.generalSettings == [0xD1, 0xD2])
    }

    @Test func state() throws {
        #expect(try message(XM5.battery) == .battery(BatteryStatus(level: 55)))
        #expect(try message(XM5.noiseControl) == .noiseControl(NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: false, ambientLevel: 12)))
        #expect(try message(XM5.ncAmbButton) == .ncAmbButton(.ncAmbient))
        #expect(try message(XM5.autoPowerOffOptions) == .autoPowerOffOptions(wearingDetection: true, [0x10, 0x11]))
        #expect(try message(XM5.touchPanel) == .generalSettingCapability(GeneralSettingCapability(
            inquiredType: 0xD1, settingType: 0, stringFormat: 1, subject: "TOUCH_PANEL_SETTING", summary: "")))
    }

    @Test func equalizerWithUnnamedPresets() throws {
        guard case let .equalizerPresets(_, bands, steps, presets) = try message(XM5.eqPresets) else { Issue.record(); return }
        #expect(bands == 6 && steps == 21)
        #expect(presets.map(\.id) == [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0, 0xA1, 0xA2])
        #expect(presets.allSatisfy { $0.name.isEmpty })
        #expect(presets.map(\.displayName).prefix(3) == ["Off", "Bright", "Excited"])
        guard case .equalizer(let eq) = try message(XM5.eq) else { Issue.record(); return }
        #expect(eq.presetID == 0xA2 && eq.clearBass == 9 && eq.bands == [0, 0, 2, 4, 6])
    }
}
