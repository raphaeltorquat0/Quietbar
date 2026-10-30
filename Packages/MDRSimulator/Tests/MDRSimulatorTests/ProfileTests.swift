import MDRKit
import MDRSession
import Testing
@testable import MDRSimulator

@Suite struct ProfileTests {
    @Test func coversTheCompatibilityTable() {
        let models = Set(Profiles.all.map(\.modelName))
        #expect(models == ["WH-1000XM5", "WH-1000XM6", "WH-CH720N", "ULT WEAR", "WF-1000XM4", "WF-1000XM5", "WF-1000XM6",
                           "WF-C500", "WF-C510", "WF-C700N", "WF-C710N", "LinkBuds", "LinkBuds S", "LinkBuds Open", "LinkBuds Clip"])
        #expect(Set(Profiles.all.map(\.id)).count == Profiles.all.count)
    }

    @Test func onlyTheThreeCapturedModelsClaimACapture() {
        #expect(Set(Profiles.all.filter(\.isCapture).map(\.modelName)) == ["WH-1000XM5", "WF-1000XM5", "LinkBuds Clip"])
    }

    @Test(arguments: Profiles.all.map(\.id))
    func declaresOriginAndGaps(_ id: String) throws {
        let p = try #require(Profiles.find(id))
        #expect(!p.gaps.isEmpty, "todo perfil tem lacunas declaradas")
        switch p.origin {
        case let .capture(fixtures, source):
            #expect(!source.isEmpty)
            for f in fixtures { #expect(!CapturedFrames.frames(f).isEmpty) }
        case .reference(let citations):
            #expect(!citations.isEmpty)
            #expect(citations.allSatisfy { !$0.project.isEmpty && !$0.file.isEmpty && !$0.license.isEmpty })
            // Sem bytes reais, o perfil tem que dizer isso.
            #expect(p.gaps.contains { $0.contains("nunca foram vistos") })
        }
    }

    @Test func findsByIdAndByModelName() {
        #expect(Profiles.find("wh1000xm5")?.modelName == "WH-1000XM5")
        #expect(Profiles.find("WF-C510")?.id == "wfc510")
        #expect(Profiles.find("LinkBuds S")?.id == "linkbudss")
        #expect(Profiles.find("WH-1000XM4") == nil)
    }
}

/// O que a UI faz, de ponta a ponta, por `MDRSession`. Cada passo só roda se o fone anunciar o recurso.
@Suite struct UIFlowTests {
    @Test(arguments: Profiles.all.map(\.id))
    func fullFlow(_ id: String) async throws {
        let profile = try #require(Profiles.find(id))
        let (t, s) = try await connected(profile)

        // Handshake e leitura do painel.
        #expect(await s.state.modelName == profile.modelName)
        #expect(await s.phase == .ready)
        let caps = await s.state.capabilities
        #expect(!caps.table1.isEmpty)
        #expect(await eventually(s) { $0.primaryBattery != nil })
        if case .earbuds = profile.features.battery { #expect(caps.isEarbuds) }

        // Modo de som e ambiente.
        if caps.noiseControlType != nil {
            #expect(await eventually(s) { $0.noiseControl != nil })
            let type = await s.state.noiseControl?.inquiredType
            for mode in type == 0x22 ? [SoundMode.ambient, .off] : [.ambient, .noiseCanceling, .off] {
                try await s.setSoundMode(mode)
                #expect(await eventually(s) { $0.noiseControl?.soundMode == mode })
            }
            try await s.setSoundMode(.ambient)
            try await s.setAmbientLevel(7)
            #expect(await eventually(s) { $0.noiseControl?.ambientLevel == 7 })
            try await s.setFocusOnVoice(true)
            #expect(await eventually(s) { $0.noiseControl?.focusOnVoice == true })
        }

        // Equalizador: preset e curva.
        if caps.equalizerType != nil {
            #expect(await eventually(s) { !$0.equalizerPresets.isEmpty && $0.equalizer != nil })
            let state = await s.state
            let preset = try #require(state.equalizerPresets.last)
            let size = try #require(state.equalizer).steps.count
            try await s.setEqualizerPreset(preset.id)
            #expect(await eventually(s) { $0.equalizer?.presetID == preset.id && $0.equalizer?.steps.count == size })
            try await s.setEqualizer(values: Array(repeating: 2, count: size))
            #expect(await eventually(s) { $0.equalizer?.values == Array(repeating: 2, count: size) })
        }

        // Alternadores do painel e das Configurações.
        if caps.dsee {
            try await s.setDSEE(true)
            #expect(await eventually(s) { $0.dsee == true })
        }
        if caps.speakToChat {
            try await s.setSpeakToChat(true)
            #expect(await eventually(s) { $0.speakToChat == true })
        }
        if caps.autoPause {
            try await s.setAutoPause(false)
            #expect(await eventually(s) { $0.autoPause == false })
        }
        if caps.ncAmbButton {
            try await s.setNcAmbButton(.ncOff)
            #expect(await eventually(s) { $0.ncAmbButton == .ncOff })
        }
        if caps.connectionPriority {
            try await s.setConnectionPriority(ConnectionPriority(rawValue: 1))
            #expect(await eventually(s) { $0.connectionPriority?.rawValue == 1 })
        }
        if caps.autoPowerOffType != nil {
            try await s.setAutoPowerOff(0x11)
            #expect(await eventually(s) { $0.autoPowerOff?.current == 0x11 })
        }

        // Ajustes gerais; multiponto passa pelo alerta de confirmação.
        for type in caps.generalSettings {
            guard await eventually(s, { $0.generalSettings[type] != nil }) else { continue }
            let before = await s.state.generalSettings[type] ?? false
            try await s.setGeneralSetting(type, on: !before)
            if await s.state.generalSettingCapabilities[type]?.subject.hasPrefix("MULTIPOINT") == true {
                #expect(await eventually(s) { $0.pendingAlert != nil })
                try await s.respondToAlert(positive: true)
            }
            #expect(await eventually(s) { $0.generalSettings[type] == !before })
        }

        // Reprodução e volume.
        if caps.playback {
            try await s.setVolume(9)
            #expect(await eventually(s) { $0.volume == 9 })
            try await s.playback(.pause)
            #expect(await eventually(s) { $0.playback?.isPlaying == false })
            try await s.playback(.play)
            #expect(await eventually(s) { $0.playback?.isPlaying == true })
        }

        #expect(await t.device.unknownSets.isEmpty)
        await s.disconnect()
        #expect(await s.phase == .disconnected)
    }
}
