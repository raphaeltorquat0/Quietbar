import MDRKit

/// Ações de alto nível. Cada uma parte do último estado lido do fone e escolhe a variante
/// do comando pelas capacidades anunciadas.
public extension MDRSession {
    func setNoiseControl(_ change: @Sendable (inout NoiseControl) -> Void) async throws {
        guard let type = state.noiseControl?.inquiredType ?? state.capabilities.noiseControlType else {
            throw MDRSessionError.notConnected
        }
        if state.noiseControl == nil { // logo após conectar o RET pode ainda não ter chegado
            _ = try? await request(.noiseControl(type), "NC/ASM") { if case .noiseControl = $0 { true } else { false } }
        }
        var n = state.noiseControl ?? NoiseControl(inquiredType: type, enabled: true, ambientMode: false, ambientLevel: 10)
        n.dragging = false
        change(&n)
        n.ambientLevel = min(20, max(n.inquiredType == 0x22 ? 1 : 0, n.ambientLevel))
        try await set(.noiseControl(n))
    }

    func setSoundMode(_ mode: SoundMode) async throws { try await setNoiseControl { $0.soundMode = mode } }

    func setAmbientLevel(_ level: Int) async throws {
        try await setNoiseControl { $0.ambientLevel = UInt8(clamping: level) }
    }

    func setFocusOnVoice(_ on: Bool) async throws { try await setNoiseControl { $0.focusOnVoice = on } }

    func setEqualizerPreset(_ id: UInt8) async throws { try await set(.equalizer(EqualizerParam(presetID: id))) }

    /// EQ de 5 bandas + Clear Bass em dB (−10…+10). Sem `presetID`, aplica sobre o preset atual
    /// se ele for editável (Custom / User Setting), senão sobre o Custom.
    func setEqualizer(clearBass: Int, bands: [Int], presetID: UInt8? = nil) async throws {
        let current = state.equalizer?.presetID ?? EqualizerParam.customPresetID
        let preset = presetID ?? ((0xA0...0xA5).contains(current) ? current : EqualizerParam.customPresetID)
        try await set(.equalizer(EqualizerParam(presetID: preset, clearBass: clearBass, bands: bands)))
    }

    func setDSEE(_ on: Bool) async throws { try await set(.dsee(on)) }
    func setSpeakToChat(_ on: Bool) async throws { try await set(.speakToChat(on)) }
    func setSpeakToChatConfig(_ c: SpeakToChatConfig) async throws { try await set(.speakToChatConfig(c)) }
    func setAutoPause(_ on: Bool) async throws { try await set(.autoPause(on)) }
    func setNcAmbButton(_ f: NcAmbButtonFunction) async throws { try await set(.ncAmbButton(f)) }
    func setConnectionPriority(_ p: ConnectionPriority) async throws { try await set(.connectionPriority(p)) }
    func setGeneralSetting(_ type: UInt8, on: Bool) async throws { try await set(.generalSetting(inquiredType: type, on: on)) }

    func setAutoPowerOff(_ element: UInt8) async throws {
        guard let type = state.capabilities.autoPowerOffType else { throw MDRSessionError.notConnected }
        try await set(.autoPowerOff(AutoPowerOff(wearingDetection: type == 0x05, current: element, last: 0x00)))
    }

    func setAssignableButtons(_ presets: [UInt8]) async throws {
        guard let type = state.capabilities.assignableType else { throw MDRSessionError.notConnected }
        try await set(.assignableButtons(inquiredType: type, presets: presets))
    }

    /// Volume do fone (XM5: 0–30, ver docs/PROTOCOL.md).
    func setVolume(_ v: Int) async throws { try await set(.volume(UInt8(clamping: min(30, max(0, v))))) }

    func playback(_ control: PlaybackControl) async throws { try await set(.playbackControl(control)) }

    func powerOff() async throws { try await send(MDRMessage.powerOff.command(.set)) }

    /// Responde ao alerta pendente (ex.: confirmação ao alternar multiponto).
    func respondToAlert(positive: Bool) async throws {
        guard let a = takePendingAlert() else { return }
        try await send(MDRMessage.alert(messageType: a.messageType, action: positive ? 0x01 : 0x00).command(.set))
    }
}
