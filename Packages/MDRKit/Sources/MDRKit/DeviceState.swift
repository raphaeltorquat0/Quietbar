/// Estado conhecido do fone. Só muda por mensagens vindas dele (RET/NTFY) — a UI apenas reflete.
public struct MDRDeviceState: Hashable, Sendable {
    public var protocolVersion: UInt32?
    public var hasTable2 = false
    public var uniqueID: String?
    public var modelName: String?
    public var firmwareVersion: String?
    public var series: UInt8?
    public var color: UInt8?
    public var capabilities = MDRCapabilities()

    public var codec: AudioCodec?
    public var battery: BatteryStatus?
    public var autoPowerOff: AutoPowerOff?
    public var autoPowerOffOptions: [UInt8] = []
    public var noiseControl: NoiseControl?
    public var ncAmbButton: NcAmbButtonFunction?
    public var equalizerAvailable: Bool?
    public var equalizer: EqualizerParam?
    public var equalizerPresets: [EqPreset] = []
    public var dseeAvailable: Bool?
    public var dsee: Bool?
    public var dseeType: UInt8?
    public var connectionPriority: ConnectionPriority?
    public var speakToChat: Bool?
    public var speakToChatConfig: SpeakToChatConfig?
    public var autoPause: Bool?
    public var assignableButtons: [UInt8]?
    public var generalSettingCapabilities: [UInt8: GeneralSettingCapability] = [:]
    public var generalSettings: [UInt8: Bool] = [:]
    public var volume: UInt8?
    public var playback: PlaybackState?
    /// Último alerta do fone pedindo confirmação.
    public var pendingAlert: MDRAlert?

    public init() {}

    /// Endereço Bluetooth se o fone o usa como uniqueId (caso do XM5 e WF-XM5 em [C]).
    public var macAddress: String? {
        guard let id = uniqueID, id.count == 17, id.filter({ $0 == ":" }).count == 5 else { return nil }
        return id
    }

    public func generalSetting(subject: String) -> (type: UInt8, on: Bool?)? {
        generalSettingCapabilities.values.first { $0.subject == subject }.map { ($0.inquiredType, generalSettings[$0.inquiredType]) }
    }

    public mutating func apply(_ message: MDRMessage, table: MDRTable = .t1) {
        switch message {
        case let .protocolInfo(v, _, t2): protocolVersion = v; hasTable2 = t2
        case let .capabilityInfo(_, id): uniqueID = id
        case .modelName(let s): modelName = s
        case .firmwareVersion(let s): firmwareVersion = s
        case let .seriesAndColor(s, c): series = s; color = c
        case .supportFunctions(let fs):
            let set = Set(fs.map(\.function))
            if table == .t1 { capabilities.table1 = set } else { capabilities.table2 = set }
            capabilities.isFallback = false
        case .codec(let c): codec = c
        case .battery(let b): battery = b
        case .autoPowerOff(let a): autoPowerOff = a
        case .autoPowerOffOptions(_, let els): autoPowerOffOptions = els
        case .powerOff: break
        case .noiseControl(let n): noiseControl = n
        case .ncAmbButton(let f): ncAmbButton = f
        case .equalizerAvailable(let on): equalizerAvailable = on
        case .equalizer(let e): equalizer = e
        case .equalizerPresets(_, _, _, let p): equalizerPresets = p
        case .dseeAvailable(let on): dseeAvailable = on
        case .dsee(let on): dsee = on
        case .dseeType(let t): dseeType = t
        case .connectionPriority(let m): connectionPriority = m
        case .speakToChat(let on): speakToChat = on
        case .speakToChatConfig(let c): speakToChatConfig = c
        case .autoPause(let on): autoPause = on
        case .assignableButtons(_, let p): assignableButtons = p
        case .generalSettingCapability(let g): generalSettingCapabilities[g.inquiredType] = g
        case let .generalSetting(t, on): generalSettings[t] = on
        case .volume(let v): volume = v
        case .playback(let p): playback = p
        case .playbackControl, .alertsEnabled: break
        case let .alert(m, a): pendingAlert = MDRAlert(messageType: m, action: a)
        }
    }
}

public struct MDRAlert: Hashable, Sendable {
    public var messageType: UInt8
    /// `00` só confirmação, `01` positivo/negativo, `02` positivo com resposta.
    public var action: UInt8
    public init(messageType: UInt8, action: UInt8) {
        self.messageType = messageType
        self.action = action
    }
}

public extension MDRCapabilities {
    /// GETs para ler todo o estado suportado, na ordem de `RequestInitV2` de [M].
    var syncCommands: [MDRCommand] {
        var c: [MDRCommand] = []
        for t in generalSettings { c += [.generalSettingCapability(t), .generalSetting(t)] }
        if dsee { c += [.dseeType] }
        if codec { c.append(.codec) }
        if let t = batteryType { c.append(.battery(t)) }
        if playback { c += [.volume, .playback] }
        if let t = noiseControlType { c.append(.noiseControl(t)) }
        if speakToChat { c += [.speakToChat, .speakToChatConfig] }
        if let t = equalizerType { c += [.equalizerPresets(t), .equalizerAvailable, .equalizer] }
        if connectionPriority { c.append(.connectionPriority) }
        if dsee { c += [.dseeAvailable, .dsee] }
        if let t = assignableType { c.append(.assignableButtons(t)) }
        if ncAmbButton { c.append(.ncAmbButton) }
        if let t = autoPowerOffType { c += [.autoPowerOffOptions(t), .autoPowerOff(t)] }
        if autoPause { c.append(.autoPause) }
        return c
    }
}
