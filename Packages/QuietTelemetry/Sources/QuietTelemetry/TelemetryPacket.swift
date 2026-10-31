import Foundation

/// De onde veio uma troca de modo de som.
public enum ModeSource: String, Codable, CaseIterable, Sendable {
    case panel, controlCenter, hotkey, intent, physicalButton
}

/// O que disparou a automação.
public enum AutomationTrigger: String, Codable, CaseIterable, Sendable {
    case call, focus, app, wifi, shortcut
}

/// Pacote diário, schema v1 (docs/telemetry-schema.md). O que não está aqui não sai do Mac.
public struct TelemetryPacket: Encodable, Equatable, Sendable {
    public struct Sources: Encodable, Equatable, Sendable {
        var panel, controlCenter, hotkey, intent, physicalButton: Int
    }

    public struct Triggers: Encodable, Equatable, Sendable {
        var call, focus, app, wifi, shortcut: Int
    }

    public struct Automation: Equatable, Sendable {
        var enabled: Bool
        var trialDay: Int?
        var triggersFired: Triggers
        var overridesManual: Int
    }

    public static let version = 1
    /// Acima disso, todo contador vira 50, que significa "50 ou mais".
    public static let counterCap = 50

    var v = Self.version
    var installId: String
    var date: String
    var appVersion: String
    var macOSMajor: Int
    var arch: String
    var deviceModelFamily: String?
    var activeDay: Bool
    var manualModeChanges: Int
    var modeChangesBySource: Sources
    var automation: Automation
    var panelOpens: Int

    enum CodingKeys: String, CodingKey {
        case v, installId, date, appVersion, macOSMajor, arch, deviceModelFamily, activeDay
        case manualModeChanges, modeChangesBySource, automation, panelOpens
    }

    /// À mão: o sintetizado omite os nulos, e o schema pede a chave presente.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(installId, forKey: .installId)
        try c.encode(date, forKey: .date)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(macOSMajor, forKey: .macOSMajor)
        try c.encode(arch, forKey: .arch)
        try c.encode(deviceModelFamily, forKey: .deviceModelFamily)
        try c.encode(activeDay, forKey: .activeDay)
        try c.encode(manualModeChanges, forKey: .manualModeChanges)
        try c.encode(modeChangesBySource, forKey: .modeChangesBySource)
        try c.encode(automation, forKey: .automation)
        try c.encode(panelOpens, forKey: .panelOpens)
    }

    /// Mesmos bytes no envio e em "Ver o que é enviado".
    public func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
}

extension TelemetryPacket.Automation: Encodable {
    enum CodingKeys: String, CodingKey { case enabled, trialDay, triggersFired, overridesManual }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(trialDay, forKey: .trialDay)
        try c.encode(triggersFired, forKey: .triggersFired)
        try c.encode(overridesManual, forKey: .overridesManual)
    }
}

/// Só a lista conhecida: o nome dado ao fone no Bluetooth nunca chega aqui, e um modelo novo vira "other".
public enum ModelFamily {
    /// Modelos dos perfis de `MDRSimulator`, conferidos em teste. Mantenha igual a `infra/telemetry/lambda/schema.ts`.
    public static let known = [
        "WH-1000XM6", "WH-1000XM5", "WH-CH720N", "ULT WEAR",
        "WF-1000XM6", "WF-1000XM5", "WF-1000XM4", "WF-C710N", "WF-C700N", "WF-C510", "WF-C500",
        "LinkBuds Clip", "LinkBuds Open", "LinkBuds S", "LinkBuds",
    ]

    /// `reported` é o modelo que o fone informa por MDR. Maiores primeiro, para "LinkBuds S" não cair em "LinkBuds".
    public static func normalize(_ reported: String?) -> String? {
        guard let reported else { return nil }
        return known.first { reported == $0 || reported.hasPrefix($0 + " ") } ?? "other"
    }
}
