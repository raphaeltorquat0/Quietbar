import Testing
@testable import MDRKit

private func decoded(_ hex: String) throws -> (MDRVerb, MDRMessage) {
    let f = try MDRFrame(decoding: [UInt8](hex: hex))
    return try #require(MDRMessage.decode(f.payload, table: f.type == .mdrNo2 ? .t2 : .t1))
}

@Suite struct CapturedMessageTests {
    @Test func identity() throws {
        #expect(try decoded(Captured.protocolInfo).1 == .protocolInfo(version: 0x0300_3018, table1: true, table2: true))
        #expect(try decoded(Captured.capabilityInfo).1 == .capabilityInfo(counter: 0x0B, uniqueID: "AC:80:0A:C1:F3:B0"))
        #expect(try decoded(Captured.firmware).1 == .firmwareVersion("6.1.0"))
        #expect(try decoded(Captured.model).1 == .modelName("WF-1000XM5"))
        #expect(try decoded(Captured.series).1 == .seriesAndColor(series: 0x30, color: 0x03))
    }

    @Test func supportFunctions() throws {
        guard case .supportFunctions(let t1) = try decoded(Captured.supportT1).1 else { Issue.record(); return }
        #expect(t1.count == 46)
        #expect(t1.first == SupportFunction(0x10, priority: 0xFF))
        guard case .supportFunctions(let t2) = try decoded(Captured.supportT2).1 else { Issue.record(); return }
        #expect(t2.count == 11)

        var s = MDRDeviceState()
        s.apply(.supportFunctions(t1))
        s.apply(.supportFunctions(t2), table: .t2)
        #expect(s.capabilities.noiseControlType == 0x17)
        #expect(s.capabilities.equalizerType == 0x00)
        #expect(s.capabilities.speakToChat && s.capabilities.dsee && s.capabilities.codec)
        #expect(s.capabilities.generalSettings == [0xD1, 0xD2])
        // T2 real: `42 3D(escapado) … 31 FF` — 0x31 (SOURCE_SWITCH_CONTROL) é função, 0x30 só aparece como prioridade.
        #expect(s.capabilities.table2.contains(0x31) && s.capabilities.table2.contains(0x42))
        #expect(!s.capabilities.table2.contains(0x30))
    }

    @Test func generalSettings() throws {
        #expect(try decoded(Captured.multipointCapability).1 == .generalSettingCapability(GeneralSettingCapability(
            inquiredType: 0xD2, settingType: 0, stringFormat: 1,
            subject: "MULTIPOINT_SETTING", summary: "MULTIPOINT_SETTING_SUMMARY_LDAC_AVAILABLE")))
        #expect(try decoded(Captured.multipointParam).1 == .generalSetting(inquiredType: 0xD2, on: true))
        #expect(try decoded(Captured.gsParam).1 == .generalSetting(inquiredType: 0xD1, on: false))
    }

    @Test func soundAndPlayback() throws {
        #expect(try decoded(Captured.codec).1 == .codec(.aac))
        #expect(try decoded(Captured.volume).1 == .volume(12))
        #expect(try decoded(Captured.playback).1 == .playback(PlaybackState(status: 0x02, enabled: true, inCall: false)))
        #expect(try decoded(Captured.noiseControl).1 == .noiseControl(NoiseControl(
            inquiredType: 0x17, dragging: false, enabled: false, ambientMode: true, focusOnVoice: false, ambientLevel: 20)))
        #expect(try decoded(Captured.speakToChat).1 == .speakToChat(false))
        #expect(try decoded(Captured.speakToChatConfig).1 == .speakToChatConfig(SpeakToChatConfig(sensitivity: 0, modeOutTime: 0)))
        #expect(try decoded(Captured.dseeAvailable).1 == .dseeAvailable(true))
        #expect(try decoded(Captured.dsee).1 == .dsee(true))
        #expect(try decoded(Captured.dseeType).1 == .dseeType(0x02))
        #expect(try decoded(Captured.eqAvailable).1 == .equalizerAvailable(true))
        #expect(try decoded(Captured.assignable).1 == .assignableButtons(inquiredType: 0x03, presets: [0x35, 0x20]))
        #expect(try decoded(Captured.autoPowerOff).1 == .autoPowerOff(AutoPowerOff(wearingDetection: true, current: 0x10, last: 0x00)))
        #expect(try decoded(Captured.autoPause).1 == .autoPause(true))
    }

    @Test func equalizerBands() throws {
        guard case .equalizer(let eq) = try decoded(Captured.eqParam).1 else { Issue.record(); return }
        #expect(eq.presetID == EqualizerParam.customPresetID)
        #expect(eq.clearBass == 10)
        #expect(eq.bands == [1, 0, 3, -1, 2])
        #expect(EqualizerParam(clearBass: 10, bands: [1, 0, 3, -1, 2]) == eq)
        #expect(EqualizerParam(clearBass: 99, bands: [-50, 0, 0, 0, 0]).steps == [20, 0, 10, 10, 10, 10])
    }

    @Test func soundModeMapping() {
        var n = NoiseControl(enabled: false, ambientMode: true, ambientLevel: 20)
        #expect(n.soundMode == .off)
        n.soundMode = .noiseCanceling
        #expect(n.enabled && !n.ambientMode)
        n.soundMode = .ambient
        #expect(n.enabled && n.ambientMode)
    }
}

@Suite struct EncodingTests {
    @Test func setVectorsMatchReferences() {
        // [G] SonyProtocolImplV2Test: EQ preset Bright → payload `58 00 10 00`.
        #expect(MDRMessage.equalizer(EqualizerParam(presetID: 0x10)).command().payload == [0x58, 0x00, 0x10, 0x00])
        // [G] DSEE on → `E8 01 01`; [G] conexão "qualidade" → `E8 00 00`.
        #expect(MDRMessage.dsee(true).command().payload == [0xE8, 0x01, 0x01])
        #expect(MDRMessage.connectionPriority(.soundQuality).command().payload == [0xE8, 0x00, 0x00])
        // [M] PowerSetStatusPowerOff → `24 03 01`.
        #expect(MDRMessage.powerOff.command().payload == [0x24, 0x03, 0x01])
        // [M] NcAsmSetParamModeNcDualModeSwitchAsmSeamless: NC ligado, nível 20.
        let nc = NoiseControl(inquiredType: 0x17, enabled: true, ambientMode: false, ambientLevel: 20)
        #expect(MDRMessage.noiseControl(nc).command().payload == [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14])
        #expect(MDRMessage.playbackControl(.next).command().payload == [0xA4, 0x01, 0x00, 0x02])
        #expect(MDRMessage.alertsEnabled(true).command().payload == [0x94, 0x00, 0x00])
        #expect(MDRMessage.speakToChat(true).command().payload == [0xF8, 0x0C, 0x00, 0x01])
        #expect(MDRMessage.generalSetting(inquiredType: 0xD2, on: false).command().payload == [0xD8, 0xD2, 0x00, 0x01])
    }

    @Test func getVectors() {
        #expect(MDRCommand.protocolInfo.payload == [0x00, 0x00])
        #expect(MDRCommand.noiseControl(0x17).payload == [0x66, 0x17])
        #expect(MDRCommand.equalizer.payload == [0x56, 0x00])
        #expect(MDRCommand.speakToChatConfig.payload == [0xFA, 0x0C])
        #expect(MDRCommand.generalSettingCapability(0xD1).payload == [0xD0, 0xD1, 0x01])
        #expect(MDRCommand.codec.payload == [0x12, 0x02])
        #expect(MDRCommand.supportFunctions(.t2) == MDRCommand([0x06, 0x00], table: .t2))
    }

    static let allMessages: [MDRMessage] = [
        .protocolInfo(version: 0x0102_0304, table1: true, table2: false),
        .capabilityInfo(counter: 3, uniqueID: "00:11:22:33:44:55"),
        .modelName("WH-1000XM5"), .firmwareVersion("2.5.1"), .seriesAndColor(series: 0x30, color: 0x01),
        .supportFunctions([SupportFunction(0x6B, priority: 8), SupportFunction(0xFC)]),
        .codec(.ldac),
        .battery(BatteryStatus(level: 80, chargingRaw: 1)),
        .battery(BatteryStatus(level: 30, chargingRaw: 0, threshold: 20)),
        .autoPowerOff(AutoPowerOff(wearingDetection: false, current: 0x11)),
        .autoPowerOffOptions(wearingDetection: true, [0x00, 0x10, 0x11]),
        .powerOff,
        .noiseControl(NoiseControl(inquiredType: 0x15, dragging: true, enabled: true, ambientMode: true, focusOnVoice: true, ambientLevel: 7)),
        .noiseControl(NoiseControl(inquiredType: 0x19, enabled: true, ambientMode: false, ambientLevel: 1, extra: [0x00, 0x01])),
        .noiseControl(NoiseControl(inquiredType: 0x22, enabled: true, ambientMode: true, focusOnVoice: false, ambientLevel: 20)),
        .ncAmbButton(.ncOff),
        .equalizerAvailable(false),
        .equalizer(EqualizerParam(clearBass: -3, bands: [1, 2, 3, 4, 5])),
        .equalizerPresets(inquiredType: 0, bands: 6, steps: 21, [EqPreset(id: 0x10, name: "Bright"), EqPreset(id: 0xA0, name: "Custom")]),
        .dseeAvailable(true), .dsee(false), .dseeType(3),
        .connectionPriority(.stability),
        .speakToChat(true), .speakToChatConfig(SpeakToChatConfig(sensitivity: 2, modeOutTime: 3)),
        .autoPause(false),
        .assignableButtons(inquiredType: 0x03, presets: [0x00]),
        .generalSettingCapability(GeneralSettingCapability(inquiredType: 0xD1, subject: "TOUCH_PANEL_SETTING", summary: "")),
        .generalSetting(inquiredType: 0xD3, on: true),
        .volume(30),
        .playback(PlaybackState(status: 1, enabled: true, inCall: true)),
        .alertsEnabled(false),
        .alert(messageType: 0x06, action: 0x01),
    ]

    @Test(arguments: allMessages)
    func roundTripThroughFrame(_ m: MDRMessage) throws {
        let verbs: [MDRVerb] = switch m {
        case .protocolInfo, .capabilityInfo, .modelName, .firmwareVersion, .seriesAndColor, .supportFunctions: [.ret]
        case .equalizerPresets, .autoPowerOffOptions, .dseeType, .generalSettingCapability: [.ret]
        case .playback: [.ret, .notify] // SET de playback status tem o layout de controle
        default: [.ret, .notify, .set]
        }
        for v in verbs {
            let cmd = m.command(v)
            let raw = MDRFrame(type: cmd.table.dataType, seq: 1, payload: cmd.payload).encoded()
            let f = try MDRFrame(decoding: raw)
            let back = try #require(MDRMessage.decode(f.payload, table: cmd.table))
            #expect(back.0 == v)
            #expect(back.1 == m)
        }
    }

    @Test func setPlaybackControlRoundTrip() throws {
        let p = MDRMessage.playbackControl(.play).command(.set).payload
        #expect(MDRMessage.decode(p)?.1 == .playbackControl(.play))
    }

    @Test func rejectsTruncatedAndUnknown() {
        #expect(MDRMessage.decode([0x67, 0x17, 0x01]) == nil)
        #expect(MDRMessage.decode([0x57, 0x00, 0xA0, 0x06, 0x14]) == nil)
        #expect(MDRMessage.decode([0x66, 0x17]) == nil) // GET não é estado
        #expect(MDRMessage.decode([0x3F, 0x00]) == nil) // firmware: fora de escopo
        #expect(MDRMessage.decode([]) == nil)
    }

    @Test func refreshForSets() {
        let nc = NoiseControl(inquiredType: 0x15, enabled: true, ambientMode: false, ambientLevel: 1)
        #expect(MDRMessage.noiseControl(nc).refresh == .noiseControl(0x15))
        #expect(MDRMessage.generalSetting(inquiredType: 0xD2, on: true).refresh == .generalSetting(0xD2))
        #expect(MDRMessage.powerOff.refresh == nil)
    }
}

@Suite struct CapabilityTests {
    @Test func fallbackProfile() {
        let c = MDRCapabilities.wh1000xm5
        #expect(c.isFallback)
        #expect(c.noiseControlType == 0x17)
        #expect(c.batteryType == 0x00)
        #expect(c.autoPowerOffType == 0x05)
        #expect(c.assignableType == nil) // o XM5 real não anuncia 0xF3/0xFE
        #expect(c.ncAmbButton && c.speakToChat && c.dsee && c.alerts)
        #expect(c.syncCommands.contains(.speakToChatConfig))
        #expect(!MDRCapabilities().syncCommands.contains(.codec))
    }

    @Test func variantSelection() {
        #expect(MDRCapabilities(table1: [0x68]).noiseControlType == 0x15)
        #expect(MDRCapabilities(table1: [0x6D]).noiseControlType == 0x19)
        #expect(MDRCapabilities(table1: [0x67]).noiseControlType == 0x22)
        #expect(MDRCapabilities(table1: [0x28]).batteryType == 0x08)
        #expect(MDRCapabilities(table1: [0xFE, 0xF3]).assignableType == 0x0E)
    }

    @Test func stateHelpers() {
        var s = MDRDeviceState()
        s.apply(.capabilityInfo(counter: 1, uniqueID: "AC:80:0A:C1:F3:B0"))
        #expect(s.macAddress == "AC:80:0A:C1:F3:B0")
        s.apply(.generalSettingCapability(GeneralSettingCapability(inquiredType: 0xD2, subject: "MULTIPOINT_SETTING", summary: "")))
        s.apply(.generalSetting(inquiredType: 0xD2, on: true))
        #expect(s.generalSetting(subject: "MULTIPOINT_SETTING")?.on == true)
        s.apply(.alert(messageType: 6, action: 1))
        #expect(s.pendingAlert == MDRAlert(messageType: 6, action: 1))
    }
}
