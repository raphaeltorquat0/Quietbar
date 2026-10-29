import Foundation

private func onOff(_ b: Bool?) -> String { b.map { $0 ? "on" : "off" } ?? "—" }
private func hex(_ b: UInt8) -> String { String(format: "0x%02X", b) }

public extension MDRDeviceState {
    /// Pares campo/valor do `mdr-cli dump` e do "Copiar diagnóstico" do app.
    var diagnosticFields: [(String, String)] {
    let s = self
    let caps = s.capabilities
    var f: [(String, String)] = [
        ("model", s.modelName ?? "—"),
        ("firmware", s.firmwareVersion ?? "—"),
        ("mac", s.macAddress ?? s.uniqueID ?? "—"),
        ("protocol", s.protocolVersion.map { String(format: "0x%08X", $0) } ?? "—"),
        ("capabilities", (caps.isFallback ? "[perfil WH-1000XM5 de fallback] " : "")
            + "T1 " + caps.table1.sorted().map(hex).joined(separator: " ")
            + (caps.table2.isEmpty ? "" : " | T2 " + caps.table2.sorted().map(hex).joined(separator: " "))),
        ("codec", s.codec?.description ?? "—"),
        ("battery", s.battery.map { "\($0.level)%" + ($0.isCharging ? " (carregando)" : "") } ?? "—"),
    ]
    if let n = s.noiseControl {
        f += [("mode", n.soundMode.rawValue), ("ambient", "\(n.ambientLevel)"), ("voice", onOff(n.focusOnVoice)),
              ("nc-type", hex(n.inquiredType))]
    }
    if let e = s.equalizer {
        let name = EqPreset(id: e.presetID, name: s.equalizerPresets.first { $0.id == e.presetID }?.name ?? "").displayName
        f.append(("eq", name))
        if let cb = e.clearBass { f.append(("eq-bands", ([cb] + e.bands).map(String.init).joined(separator: ","))) }
    }
    if !s.equalizerPresets.isEmpty {
        f.append(("eq-presets", s.equalizerPresets.map { "\(hex($0.id))=\($0.displayName)" }.joined(separator: " ")))
    }
    f += [("eq-available", onOff(s.equalizerAvailable)), ("dsee", onOff(s.dsee)),
          ("dsee-available", onOff(s.dseeAvailable)),
          ("priority", s.connectionPriority.map { $0 == .soundQuality ? "quality" : "stability" } ?? "—"),
          ("stc", onOff(s.speakToChat)),
          ("stc-config", s.speakToChatConfig.map { "sens=\($0.sensitivity) time=\($0.modeOutTime)" } ?? "—"),
          ("autopause", onOff(s.autoPause)),
          ("autooff", s.autoPowerOff.map { AutoPowerOff.label($0.current) } ?? "—"),
          ("autooff-options", s.autoPowerOffOptions.map(AutoPowerOff.label).joined(separator: ", ")),
          ("button", s.ncAmbButton.map { hex($0.rawValue) } ?? "—"),
          ("assignable", s.assignableButtons?.map(AssignablePreset.label).joined(separator: " / ") ?? "—"),
          ("volume", s.volume.map(String.init) ?? "—"),
          ("playback", s.playback.map { $0.isPlaying ? "playing" : "paused/stopped" } ?? "—")]
    for (t, cap) in s.generalSettingCapabilities.sorted(by: { $0.key < $1.key }) {
        f.append(("gs \(hex(t))", "\(cap.subject) = \(onOff(s.generalSettings[t]))"))
    }
    return f
}
}

public extension MDRFrame {
    /// Mensagem decodificada de um frame cru (nil para ACK ou bytes que não decodificam).
    static func describe(_ bytes: [UInt8]) -> String? {
        guard let f = try? MDRFrame(decoding: bytes) else { return nil }
        if f.type == .ack { return "ACK" }
        guard let (verb, m) = MDRMessage.decode(f.payload, table: f.type == .mdrNo2 ? .t2 : .t1) else { return nil }
        return "\(verb) \(m)"
    }
}
